defmodule Fiddler do
  @moduledoc """
  Fiddler module provides functions to attach the proxy server address and port to a `:req` request.
  """

  def attach(%Req.Request{} = req) do
    case proxy_settings() do
      nil -> req
      {:ok, addr, port} -> attach(req, addr, port)
    end
  end

  @doc """
  Attaches the proxy server address and port to the request.
  """
  def attach(%Req.Request{} = req, ip_address, port) do
    req
    |> Req.merge(
      connect_options: [
        # proxy_headers: [ {"proxy-authorization", "Basic " <> Base.encode64("user:pass")} ],
        proxy: {:http, ip_address, port, []},
        transport_opts: [
          # https://hexdocs.pm/mint/Mint.HTTP.html#connect/4-transport-options
          verify: :verify_none
          ## openssl x509 -inform der -in FiddlerRoot.cer -out FiddlerRoot.pem
          # cacertfile: Path.join([System.user_home!(), "FiddlerRoot.pem"])
        ]
      ]
    )
  end

  @doc """
  Fetches the proxy server address and port from the Windows registry.

  Returns `{:ok, port}` if the proxy server is set.
  Returns `nil` if the proxy server is not set.
  """
  def fetch_proxy_server do
    System.cmd(
      "reg.exe",
      [
        "query",
        "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
        "/v",
        "ProxyServer"
      ],
      stderr_to_stdout: true
    )
    |> case do
      {output, 0} ->
        {port, ""} = extract_port(output)
        {:ok, port}

      {_, 1} ->
        nil
    end
  end

  def fetch_proxy_enabled do
    try do
      case System.cmd(
             "reg.exe",
             [
               "query",
               "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
               "/v",
               "ProxyEnable"
             ],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          parse_proxy_enable(output)

        {error, _} ->
          {:error, "Command failed: #{error}"}
      end
    rescue
      e in ErlangError -> {:error, "System command failed: #{inspect(e)}"}
    end
  end

  defp parse_proxy_enable(output) do
    case Regex.run(~r/ProxyEnable\s+REG_DWORD\s+0x([0-9a-fA-F]+)/, output) do
      [_, value] ->
        case Integer.parse(value, 16) do
          {1, _} -> {:ok, true}
          {0, _} -> {:ok, false}
          _ -> {:error, :unexpected_value}
        end

      nil ->
        {:error, :no_match}
    end
  end

  # @doc"""
  # Extracts the port number from the output of the `reg.exe` command.
  # """
  defp extract_port(output) do
    output
    |> String.trim()
    |> String.split("\r\n")
    |> Enum.at(-1)
    |> (&Regex.run(~r/^\s*ProxyServer\s+REG_SZ\s+http=127.0.0.1:(.*);/, &1)).()
    |> Enum.at(-1)
    |> Integer.parse()
  end

  @doc """
  Fetches the IP address of the machine.
  """
  def get_address do
    {output, 0} = System.cmd("ipconfig.exe", [])

    output
    |> String.split("\r\n")
    |> Enum.filter(&String.contains?(&1, "IPv4"))
    |> Enum.map(&Regex.run(~r/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/, &1))
  end

  @doc """
  Fetches the proxy settings.

  Returns `{:ok, addr, port}` if the proxy server is set.
  Returns `nil` if the proxy server is not set.
  """
  def proxy_settings do
    case fetch_proxy_server() do
      {:ok, port} ->
        addr =
          get_address()
          |> List.flatten()
          |> Enum.uniq()
          |> Enum.filter(&String.contains?(&1, "192.168"))
          |> hd

        {:ok, addr, port}

      nil ->
        nil
    end
  end
end
