defmodule Echo.Hardware.Ethernet do

  @moduledoc """

  Ethernet is an Actor that manages the configuration of an ethernet port.

  By default, Hardware.Ethernet attempts to configure an ethernet port by using
  DHCP, reverting to static configuration if that fails.  It can also
  be used to statically configure a port upon request.

  Ethernet is implemented as a GenServer.
    
  # Support for AIPA / ipv4ll addressing
  
  If an IP cannot be obtained, Ethernet automatically configures an address
  on the 169.254.0.0/16 network.  Microsoft calls this AIPA, and the IETF
  calls it ipv4ll (ipv4 link local) addressing.   
  
  Once a node has an ipv4ll address, it broadcasts a DHCP DISCOVER packet on 
  a regular basis to see if a DHCP server re-appears.  The time of this 
  rebroadcast is progressive (see ip4ll_dhcp_retry_time).   It also retries if it
  gets an SSDP notification from a client on another network.

  # Configuration parameters (sent as Elixir map)

  ifname    - The ethernet interface (defaults to "eth0")
  hostname  - hostname to pass during a DHCP request (defaults to none)

  ip, subnet, mask, router, dns - for static configuration

  TODO write genserver request helper
  """

  use GenServer

  require Logger
  require Hub
  
  alias Echo.Hardware.Led
  alias Echo.Hardware.Firmware
  
  @default_interface    "eth0"
  @default_hostname     "nemo"

  @udhcpc_script_path   "/tmp/udhcpc.sh"

  @useful_dhcp_keys     [:status, :interface, :ip, :subnet, :mask, :timezone, :router,
                         :timesvr, :dns, :hostname, :domain, :ipttl, :broadcast, :ntpsrv,
                         :opt53, :lease, :dhcptype, :serverid, :message]

  @ssdp_ip_auto_uri     "sys/ip/auto"
  @ssdp_ip_static_uri   "sys/ip/static"

  @ip4ll_dhcp_retry_interval 60000       # once a minute

  @initial_state %{ interface: "eth0", hostname: "echo", status: "init" }
  
  def start(state \\ %{}) do
    :gen_server.start __MODULE__, state, []
  end

  def start_link(state \\ %{}) do
    :gen_server.start_link __MODULE__, state, []
  end
  
  # a few assorted helpers to delegate to native erlang 

  defp el2b(l), do: :erlang.list_to_binary(l)
  defp eb2l(b), do: :erlang.binary_to_list(b)
  defp eb2a(b), do: :erlang.binary_to_atom(b, :utf8)
  defp os_cmd(cmd) do
    :os.cmd(eb2l(cmd)) |> el2b
  end
 
  @doc """
  Initializes the genserver (setting up the ethernet)
  """
  def init(state) do
    init_dhcp_subsystem
    state = update_and_announce(@initial_state, state)
		Logger.info "started ethernet agent in state #{inspect state}"
    :os.cmd '/sbin/ip link set #{state.interface} up'
    {:ok, init_static_or_dynamic_ip(state)}
  end

  # write out a script that udhcpc can use in a client mode to do dhcp requests
  defp init_dhcp_subsystem do
    udhcpc_script="#!/bin/sh\necho [\necho status=\\'$1\\'\nset\necho ]\n"
    File.write @udhcpc_script_path, udhcpc_script
    File.chmod @udhcpc_script_path, 0777
  end

  # If we already have a static configuration in flash, honor that,
  # otherwise do dhcp with fallback to ip4ll if dhcp fails
  defp init_static_or_dynamic_ip(state) do
    case File.read(Firmware.etc_path("static_ip.conf")) do
      {:ok, data} ->
  			configure_with_static_ip(state, :erlang.binary_to_term(data))
      _ -> 
  			configure_with_dynamic_ip(state)
  	end
  end

  # setup the interface to ahve a static ip address
  defp configure_with_static_ip(state, params) do # -> new_state
    params = Dict.merge(%{status: "static"}, params)
    Logger.info "configuring static ip as #{inspect params}"
    state = update_and_announce(state, params)
    configure_interface(state, params)
  end

  # setup the interface to have a dynamic (dhcp or ip4ll) address
  defp configure_with_dynamic_ip(state) do # -> new_state
    state = update_and_announce state, status: "request"
    params = make_raw_dhcp_request(state)
    case params[:status] do
      "bound" -> configure_dhcp(state, params)
      "renew" -> configure_dhcp(state, params)
      _ -> configure_ip4ll(state)
    end
  end

  defp configure_dhcp(state, params) do
    if Dict.has_key?(params, :lease) do
      lease = :erlang.binary_to_integer(params[:lease])
      :erlang.send_after lease*1000, Kernel.self, :dhcp_lease_expired
    end
    configure_interface(state, params)
  end
  
  # setup an ipv4ll address (autoconfigured address) with timer
  defp configure_ip4ll(state) do
    params = ip4ll_params(state)
    schedule_ip4ll_dhcp_retry
    configure_interface(state, params)
  end
  
  defp ip4ll_params(state) do
    [ interface: state.interface, ip: calculate_ip4ll_ip_from_state(state),
    mask: "16", subnet: "255.255.0.0",  status: "ip4ll"  ]
  end 

  defp calculate_ip4ll_ip_from_state(state) do
    maddr = File.read! "/sys/class/net/#{state.interface}/address"
    seed = :crypto.hash(:md5, maddr)
    <<x, y, _rest :: bytes>> = seed    
    if (x==255 and y==255), do: y = y-1
    if (x==0 and y==0), do: y = y+1
    "169.254.#{x}.#{y}"
  end

  # given params, do a configuration of the interface and announce
  defp configure_interface(state, params) do
    Logger.info "setting up interface #{state.interface} with: #{inspect params}"
    if params[:ip] && params[:mask] do
      os_cmd "ip addr flush dev #{state.interface}"
      os_cmd "ip addr add #{params[:ip]}/#{params[:mask]} dev #{state.interface}"
      if params[:router] do
        os_cmd "ip route add default via #{params[:router]} dev #{state.interface}"
      end
    end
    update_and_announce(state, params)
  end

  # given "foobar='yahoo'", returns {:foobar, "yahoo"} to help parse result of
  # udhcpc into something useful for us
  defp cleanup_kv([_,kqval]) do
    [key, qval] = String.split(kqval, "=")
    [_, val] = Regex.run(~r/'(.+)'/s, qval) # remove single quotes
    {eb2a(key), val}
  end

    # call udhcpc in non-daemon mode, walking through resulting responses
  # to select the last (most relelvant) response, then convert it to
  # a hash containing only relelvant keys.
  # state is used to determine hostname and interface id
  defp make_raw_dhcp_request(state) do
    Logger.info "making dhcp req from '#{state.hostname}' on #{state.interface}"
    env = os_cmd "udhcpc -n -q -f -s #{@udhcpc_script_path} --interface=#{state.interface} -x hostname:#{state.hostname}"
    Logger.debug "Made DHCP request, got: #{inspect env}"
    [_, [last_response]] = Regex.scan ~r/\[.*\]/sr, env
    Enum.map(Regex.scan(~r/(\w+='.+')\n/r, last_response), &cleanup_kv/1)
    |> Enum.filter(fn({k,_v}) -> Enum.member?(@useful_dhcp_keys, k) end)
  end
  
  @doc """
  Called by SSDP module when UDP/HTTP verb comes in that is not NOTIFY or MSEARCH
  This feature is used to manage both manual and automatic IP configuration without
  a DHCP server, conforming to the 'static_ip' spec.
  """
  def ssdp_not_search_or_notify(packet, _ip \\ nil, _port \\ nil) do
    Logger.debug "SSDP packet #{inspect packet}"
    {[raw_http_line], raw_params} = String.split(packet, ["\r\n", "\n"]) |> Enum.split(1)
    http_line = String.downcase(raw_http_line) |> String.strip
    {[http_verb, full_uri], _rest} = String.split(http_line) |> Enum.split(2)
    # SSDP is multicast, so make URI matches our device, ignoring otherwise
    valid_root_uri = String.downcase "http://#{:ssdp_root_device.get_ip_port}#{:ssdp_root_device.get_uri}"
    if String.starts_with?(full_uri, valid_root_uri) do
      [_, rel_uri] = String.split full_uri, valid_root_uri
      Logger.debug "SSDP #{http_line} received"
      mapped_params = Enum.map raw_params, fn(x) ->
        case String.split(x, ":") do
          [k, v] -> {String.downcase(k), String.strip(v)}
          _ -> nil
        end
      end
      filtered_params = Enum.reject mapped_params, &(&1 == nil)
      Logger.debug "Parsed into params: #{inspect filtered_params}"
      GenServer.cast(:main_ethernet, {:ssdp_http, {eb2a(http_verb), rel_uri, filtered_params}})
    else
      Logger.debug "SSDP #{http_line} received, but not for me"
    end
  end

  ############################ http ssdp handlers ###########################

  # configure manual static IP
  # REVIEW: currently ignores DNS (resolver) settings, not important right now
  # TODO URGENT: hadndle multiple puts of this
  def handle_cast({:ssdp_http, {:put, @ssdp_ip_static_uri, params}}, state) do
    Logger.info "Configuring Static IP with params #{inspect params}"
    ifcfg = [ip: params["x-ip"], mask: params["x-subnet"], router: params["x-router"], status: "static"]
    state = configure_interface state, ifcfg
    {:noreply, state}
  end

  # configure automatic static ip
  def handle_cast({:ssdp_http, {:put, @ssdp_ip_auto_uri, params}}, state) do
    Logger.warning "NOT YET IMPLEMENTED - Asked to configure autohop IP with params #{inspect params}"
    {:noreply, state}
  end

  # deconfigure manual static IP
  def handle_cast({:ssdp_http, {:delete, @ssdp_ip_static_uri, _params}}, state) do
    Logger.info "Deconfiguring Static IP"
    {:noreply, configure_with_dynamic_ip(state)}
  end

  # deconfigure automatic static ip
  def handle_cast({:ssdp_http, {:delete, @ssdp_ip_auto_uri, _params}}, state) do
    Logger.info "Deconfiguring Automatic Hopping IP"
    {:noreply, configure_with_dynamic_ip(state)}
  end

  # try renewing dhcp lease upon expiration unless we've been configured 
  # as a static ip in the meantime
  def handle_info(:dhcp_lease_expired, state) do
    case state.status do
      "static" -> {:noreply, state}
      _ -> {:noreply, configure_with_dynamic_ip(state)}
    end
  end

  # called periodically to try to see if a dhcp server came back online
  def handle_info(:ip4ll_dhcp_retry, state) do
    params = make_raw_dhcp_request(state)
    case params[:status] do
      "bound" -> configure_dhcp(state, params)
      "renew" -> configure_dhcp(state, params)
      _ -> schedule_ip4ll_dhcp_retry
    end
    {:noreply, state}
  end
  
  defp schedule_ip4ll_dhcp_retry do
    :erlang.send_after @ip4ll_dhcp_retry_interval, Kernel.self, :ip4ll_dhcp_retry
  end

  def _request(path, changes, _context, _from, _state) do
    Log.info "Request to update #{path} with changes #{changes} received"
  end
  ############################ updating /announcing ############################

  # update the state and annouce new status
  defp update_and_announce(state, changes) do
    state = Dict.merge(state, changes)
    Hub.put([:sys, :ip, state.interface], changes)
    if Dict.has_key?(changes, :status) do
      set_led_from_status changes[:status]
    end
    state
  end

  # make the status light reflect, well, status
  defp set_led_from_status(status) do
    case status do
      "static" -> true
      "bound" -> true
      "ip4ll" -> :slowwink
      "request" -> :heartbeat
      _ -> :slowblink
    end 
    |> set_led_pattern
  end

  defp set_led_pattern(pattern) do
    Led.set :power, pattern
  end
  
end