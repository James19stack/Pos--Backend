defmodule Pos.Accounts.User do
  use Pos.Schema

  @roles [:cashier, :supervisor, :manager, :admin]

  schema "users" do
    field :name, :string
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :pin_hash, :string, redact: true
    field :role, Ecto.Enum, values: @roles, default: :cashier
    field :active, :boolean, default: true

    timestamps()
  end

  def roles, do: @roles

  def at_least?(%__MODULE__{role: role}, min_role),
    do: Enum.find_index(@roles, &(&1 == role)) >= Enum.find_index(@roles, &(&1 == min_role))

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :password, :role, :active])
    |> validate_required([:name, :email, :password, :role])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  def update_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :role, :active])
    |> validate_required([:name, :role])
  end

  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password) do
    Bcrypt.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  defp put_password_hash(%{valid?: true, changes: %{password: pw}} = changeset) do
    changeset
    |> put_change(:password_hash, Bcrypt.hash_pwd_salt(pw))
    |> delete_change(:password)
  end

  defp put_password_hash(changeset), do: changeset
end
