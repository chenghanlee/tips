defmodule TipsWeb.AuthMailAdmission do
  @moduledoc """
  Admission for LiveViews that request authentication mail: sign-up, sign-in
  (including reauthentication) and email change.

  `assign_identity/2` runs in `mount/3`. It keeps the transport peer from
  `TipsWeb.ClientIdentity` and the limiter; only the server-signed session can
  replace the limiter, as tests do. `admit/2` then charges
  `Tips.AdmissionLimiter.check_auth/3` for the typed destination before any
  token or mail. Event params never choose the identity.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Tips.AdmissionLimiter
  alias TipsWeb.ClientIdentity

  @doc "Assigns the trusted client IP and the limiter. Call it in `mount/3`."
  def assign_identity(socket, session) do
    assign(socket,
      client_ip: ClientIdentity.from_socket(socket),
      limiter: session["admission_limiter"] || AdmissionLimiter
    )
  end

  @doc """
  Charges one authentication mail request for `destination`.

  Returns `:ok` or the limiter's error; a connection without a trusted peer
  returns `{:error, :no_client_ip}` without charging.
  """
  @spec admit(map(), term()) ::
          :ok
          | {:error, {:rate_limited | :capacity, pos_integer()}}
          | {:error, :invalid_identity | :no_client_ip}
  def admit(%{client_ip: {:ok, ip}, limiter: limiter}, destination),
    do: AdmissionLimiter.check_auth(destination, ip, limiter)

  def admit(%{client_ip: {:error, :invalid_identity}}, _destination), do: {:error, :no_client_ip}

  @doc "Formats a retry delay for user feedback."
  def retry_in(1), do: "1 second"
  def retry_in(seconds), do: "#{seconds} seconds"

  @doc "Feedback for a connection without a trusted peer."
  def no_client_ip_message,
    do: "We couldn't identify your connection. Reload the page and try again."
end
