defmodule TipsWeb.ClientIdentity do
  @moduledoc """
  The trusted client IP for `Tips.AdmissionLimiter.check_auth/3`.

  Both functions read only the transport peer address. They ignore forwarded
  headers (`x-forwarded-for`, `forwarded`, `x-real-ip`, `cf-connecting-ip`),
  params, LiveView connect params and event fields, because clients control all
  of them. Missing peer data returns `{:error, :invalid_identity}`; there is no
  shared fallback identity.

  Trusting a proxy's forwarded address is deployment work (P13b.01): it must
  rewrite the transport address only for the configured proxy path.
  """

  import Phoenix.LiveView, only: [get_connect_info: 2]

  @doc "Returns the peer address of an HTTP request."
  @spec from_conn(Plug.Conn.t()) :: {:ok, :inet.ip_address()} | {:error, :invalid_identity}
  def from_conn(%Plug.Conn{remote_ip: ip}), do: validate(ip)

  @doc """
  Returns the peer address of a LiveView connection.

  Call it in `mount/3`, the only place connect info is available, and keep the
  result in assigns for later events. The endpoint's `/live` socket must list
  `:peer_data` in `connect_info` for both transports.
  """
  @spec from_socket(Phoenix.LiveView.Socket.t()) ::
          {:ok, :inet.ip_address()} | {:error, :invalid_identity}
  def from_socket(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: ip} -> validate(ip)
      _missing -> {:error, :invalid_identity}
    end
  end

  defp validate(ip) do
    if :inet.is_ip_address(ip), do: {:ok, ip}, else: {:error, :invalid_identity}
  end
end
