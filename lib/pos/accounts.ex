defmodule Pos.Accounts do
  alias Pos.Accounts.User
  alias Pos.Repo

  def register_user(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)
  def get_user_by_email(_), do: nil

  @doc "Checks a supervisor's credentials typed in at someone else's till (voids, returns)."
  def authorize_override(email, password, min_role \\ :supervisor) do
    with {:ok, user} <- authenticate(email, password),
         true <- User.at_least?(user, min_role) do
      {:ok, user}
    else
      _ -> {:error, :invalid_approval}
    end
  end

  def authenticate(email, password) do
    user = get_user_by_email(email)

    # valid_password?/2 does a dummy hash check when user is nil (timing safety)
    if User.valid_password?(user, password) and user.active do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end
end
