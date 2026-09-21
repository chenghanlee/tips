ExUnit.start()

unless System.get_env("TIPS_BROWSER") == "1" do
  ExUnit.configure(exclude: [:browser])
end

Ecto.Adapters.SQL.Sandbox.mode(Tips.Repo, :manual)
