ExUnit.start()

unless System.get_env("TIPS_BROWSER") == "1" do
  ExUnit.configure(exclude: [:browser])
end

# Commit shared vocabulary before test transactions so fixtures only read these rows.
Tips.Content.Vocabulary.seed_tags!()
Tips.Content.Vocabulary.seed_synthetic!()
Ecto.Adapters.SQL.Sandbox.mode(Tips.Repo, :manual)
