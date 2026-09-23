ExUnit.start()

browser = if System.get_env("TIPS_BROWSER") == "1", do: [], else: [:browser]
real_provider = if Tips.ProviderConfig.mode() == :real, do: [], else: [:real_provider]
ExUnit.configure(exclude: browser ++ real_provider)

# Commit shared vocabulary before test transactions so fixtures only read these rows.
Tips.Content.Vocabulary.seed_tags!()
Tips.Content.Vocabulary.seed_synthetic!()
Ecto.Adapters.SQL.Sandbox.mode(Tips.Repo, :manual)
