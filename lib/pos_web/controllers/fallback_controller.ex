defmodule PosWeb.FallbackController do
  @moduledoc "Turns {:error, reason} from contexts into consistent JSON errors."
  use PosWeb, :controller

  alias PosWeb.ErrorResponse

  def call(conn, {:error, :not_found}),
    do: ErrorResponse.respond(conn, 404, "not_found", "Resource not found")

  def call(conn, {:error, :invalid_credentials}),
    do: ErrorResponse.respond(conn, 401, "invalid_credentials", "Wrong email or password")

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    ErrorResponse.respond(conn, 422, "validation_failed", "Validation failed", changeset_errors(changeset))
  end

  def call(conn, {:error, {:unknown_barcode, code}}) do
    ErrorResponse.respond(conn, 422, "unknown_barcode", "No product with barcode #{code}", %{barcode: code})
  end

  def call(conn, {:error, {:payment_mismatch, details}}) do
    ErrorResponse.respond(conn, 422, "payment_mismatch", "Payments do not add up to the sale total", details)
  end

  def call(conn, {:error, {:unsupported_payment_method, method}}) do
    ErrorResponse.respond(conn, 422, "unsupported_payment_method", "Payment method #{method} is not supported here yet")
  end

  # Import problems: a list of {row, error}
  def call(conn, {:error, %{errors: errors}}) when is_list(errors) do
    ErrorResponse.respond(conn, 422, "import_failed", "The file has problems. Nothing was saved.", %{errors: errors})
  end

  def call(conn, {:error, :mpesa_unavailable}) do
    ErrorResponse.respond(conn, 502, "mpesa_unavailable", "Could not reach M-Pesa. Try again, or use another payment method.")
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    ErrorResponse.respond(conn, 422, Atom.to_string(reason), Phoenix.Naming.humanize(reason))
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
