defmodule BigBill.Repo do
  use Ecto.Repo,
    otp_app: :big_bill,
    adapter: Ecto.Adapters.Postgres
end
