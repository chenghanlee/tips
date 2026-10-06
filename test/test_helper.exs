ExUnit.start()

{:ok, _} = Registry.start_link(keys: :unique, name: Tips.MailerTestAdapter)

browser = if System.get_env("TIPS_BROWSER") == "1", do: [], else: [:browser]
real_provider = if Tips.ProviderConfig.mode() == :real, do: [], else: [:real_provider]
# The parser's address-space ceiling uses prlimit, which exists only on Linux.
linux = if :os.type() == {:unix, :linux}, do: [], else: [:linux]
ExUnit.configure(exclude: browser ++ real_provider ++ linux)

# Commit shared vocabulary before test transactions so fixtures only read these rows.
Tips.Content.Vocabulary.seed_tags!()
Tips.Content.Vocabulary.seed_synthetic!()
Ecto.Adapters.SQL.Sandbox.mode(Tips.Repo, :manual)
