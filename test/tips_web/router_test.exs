defmodule TipsWeb.RouterTest do
  use ExUnit.Case, async: true

  test "sandbox builds allow browser sessions before authentication hooks" do
    hooks =
      for %{metadata: %{phoenix_live_view: {_, _, _, session}}} <-
            Phoenix.Router.routes(TipsWeb.Router),
          into: %{},
          do: {session.name, Enum.map(session.extra.on_mount, & &1.id)}

    assert hooks == %{
             current_user: [
               {TipsWeb.LiveAcceptance, :default},
               {TipsWeb.UserAuth, :mount_current_scope},
               {TipsWeb.InboxBadge, :default}
             ],
             require_authenticated_user: [
               {TipsWeb.LiveAcceptance, :default},
               {TipsWeb.UserAuth, :require_authenticated},
               {TipsWeb.InboxBadge, :default}
             ]
           }
  end

  @tag :router_compilation
  test "builds without SQL sandbox never mount the acceptance hook" do
    # Compile the actual router in another VM so this suite keeps its sandbox config.
    script = """
    import ExUnit.Assertions
    Application.delete_env(:tips, :sql_sandbox)
    Application.put_env(:tips, :dev_routes, false)
    Code.compile_file("lib/tips_web/router.ex")

    hooks =
      for %{metadata: %{phoenix_live_view: {_, _, _, session}}} <-
            Phoenix.Router.routes(TipsWeb.Router),
          into: %{},
          do: {session.name, Enum.map(session.extra.on_mount, & &1.id)}

    assert hooks == %{
      current_user: [{TipsWeb.UserAuth, :mount_current_scope}, {TipsWeb.InboxBadge, :default}],
      require_authenticated_user: [
        {TipsWeb.UserAuth, :require_authenticated},
        {TipsWeb.InboxBadge, :default}
      ]
    }
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["-pa", Path.join(Mix.Project.build_path(), "lib/*/ebin"), "--eval", script],
        env: [{"ERL_FLAGS", "+S 2"}, {"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
