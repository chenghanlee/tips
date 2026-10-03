defmodule TipsWeb.NotFoundError do
  @moduledoc """
  Raised by a page whose content read returned `{:error, :not_found}`. The
  endpoint renders the plain 404 page, with nothing from the request.
  """
  defexception message: "not found", plug_status: 404
end
