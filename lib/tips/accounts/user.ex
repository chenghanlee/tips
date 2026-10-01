defmodule Tips.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @reserved_handles ~w(admin moderator mod staff support deleted removed)

  schema "users" do
    field :handle, :string
    field :email, :string
    field :role, Ecto.Enum, values: [:user, :moderator], default: :user
    field :ban, Ecto.Enum, values: [:full]
    field :banned_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  A registration changeset for the public handle and sign-in email.

  Supports the same options as `email_changeset/3`.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :handle])
    |> validate_email(opts)
    |> validate_required([:handle])
    |> validate_format(:handle, ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{2,29}\z/)
    |> validate_change(:handle, fn :handle, handle ->
      if String.downcase(handle) in @reserved_handles do
        [handle: "is reserved"]
      else
        []
      end
    end)
    |> unique_constraint(:handle, name: :users_handle_unique)
  end

  @doc """
  Normalizes a sign-in email for storage and lookup.
  """
  def normalize_email(nil), do: nil
  def normalize_email(email), do: email |> String.trim() |> String.downcase()

  @doc """
  A user changeset for changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> update_change(:email, &normalize_email/1)
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/u,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Tips.Repo)
      |> unique_constraint(:email, name: :users_email_unique)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end
end
