defmodule PosWeb.Auth.Token do
  @moduledoc """
  Signed JWTs (HS256). The role in the token is informational: the Authenticate
  plug always reloads the user, so a demotion or deactivation takes effect
  immediately instead of when the token expires.
  """

  # One shift. Tills re-login at the start of each shift.
  @ttl_seconds 12 * 60 * 60

  def issue(user) do
    now = System.os_time(:second)

    claims = %{
      "sub" => user.id,
      "role" => to_string(user.role),
      "iat" => now,
      "exp" => now + @ttl_seconds
    }

    case Joken.Signer.sign(claims, signer()) do
      {:ok, token} -> {:ok, token, @ttl_seconds}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(token) when is_binary(token) do
    with {:ok, claims} <- Joken.Signer.verify(token, signer()),
         true <- is_integer(claims["exp"]) and claims["exp"] > System.os_time(:second) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_), do: {:error, :invalid_token}

  defp signer do
    Joken.Signer.create("HS256", Application.fetch_env!(:pos, :jwt_secret))
  end
end
