defmodule Tips.FeatureHelpers do
  @moduledoc "Browser steps shared by the feature tests through `Tips.FeatureCase`."

  import ExUnit.Assertions
  import Tips.AccountsFixtures, only: [generate_user_magic_link_token: 1]
  import Wallaby.Browser
  import Wallaby.Query, only: [button: 1, css: 1, xpath: 1]

  alias Wallaby.WebdriverClient

  @doc """
  Selects `value` with the control focused, as a reader does. WebDriver's
  option click does not reliably focus the select in headless Chrome.
  """
  def choose_focused(session, id, value) do
    execute_script(
      session,
      """
      const select = document.getElementById(arguments[0]);
      select.focus();
      select.value = arguments[1];
      select.dispatchEvent(new Event("input", {bubbles: true}));
      select.dispatchEvent(new Event("change", {bubbles: true}));
      """,
      [id, value]
    )
  end

  @doc "Asserts that the current URL matches `pattern`."
  def assert_url(session, pattern) do
    assert current_url(session) =~ pattern
    session
  end

  @doc "Asserts that the element with `id` has focus."
  def assert_focus(session, id) do
    execute_script(session, "return document.activeElement.id", [], &assert(&1 == id))
  end

  @doc "Signs `user` in through a magic link."
  # Wallaby 0.31.0's `assert_has` macro (deps/wallaby/lib/wallaby/browser.ex:1171-1183) has a
  # catch-all clause after `{:error, _}`; Dialyzer reports it at the call site.
  @dialyzer {:no_match, sign_in: 2}
  def sign_in(session, user) do
    {token, _hashed} = generate_user_magic_link_token(user)

    session
    |> visit("/users/log-in/#{token}")
    # LiveView cancels the form's submit and drops its push until the view has joined.
    |> assert_has(css(".phx-connected"))
    |> click(button("Log me in only this time"))
    # The browser matches the email itself, so no text is read from the log-in page's
    # header while the navigation replaces it.
    |> assert_has(xpath(~s|//header[contains(., "#{user.email}")]|))
  end

  @doc "Runs an async script `body` with `args` and returns its value. JS errors fail the test."
  def run_script(session, body, args \\ []) do
    script = """
    const done = arguments[arguments.length - 1]
    const args = Array.from(arguments).slice(0, -1)
    ;(async () => {
    #{body}
    })().then(
      (value) => done({ok: value ?? null}),
      (error) => done({error: String(error?.stack ?? error)}),
    )
    """

    case WebdriverClient.execute_script_async(session, script, args) do
      {:ok, %{"ok" => value}} -> value
      {:ok, %{"error" => error}} -> flunk("browser script failed:\n" <> error)
    end
  end

  # One filter on the LiveView socket's incoming frames, installed once per page:
  # it drops frames of the `drop` events and queues every frame while `held`.
  # Replies to held event pushes are tracked so `release_frames/1` can wait for them.
  @frames """
  const socket = window.liveSocket.getSocket()
  if (!window.frames$) {
    const receive = socket.onConnMessage.bind(socket)
    const push = socket.push.bind(socket)
    const frames = window.frames$ = {drop: [], held: null, awaiting: new Set(), receive}
    socket.push = (data) => {
      if (frames.held && data.event === "event") frames.awaiting.add(data.ref)
      push(data)
    }
    socket.onConnMessage = (message) => {
      const [, ref, , event] = JSON.parse(message.data)
      if (frames.drop.includes(event)) return
      if (frames.held) return frames.held.push(message)
      receive(message)
      if (event === "phx_reply") frames.awaiting.delete(ref)
    }
  }
  const frames = window.frames$
  """

  @doc """
  Drops every incoming frame of `events`, such as `"phx_reply"` and `"diff"`, as
  a lost connection would, until `reconnect_live/1`.
  """
  def drop_frames(session, events),
    do: run_script(session, @frames <> "frames.drop = args[0]", [events])

  @doc "Queues every incoming frame, as a slow network would, until `release_frames/1`."
  def hold_frames(session), do: run_script(session, @frames <> "frames.held = []")

  @doc "Waits until a queued frame is an `event` frame, such as `\"diff\"`."
  def await_held(session, event) do
    run_script(
      session,
      @frames <>
        """
        const deadline = Date.now() + 5000
        while (!frames.held.some((message) => JSON.parse(message.data)[3] === args[0])) {
          if (Date.now() > deadline) throw new Error(`no ${args[0]} frame arrived`)
          await new Promise((resolve) => setTimeout(resolve, 50))
        }
        """,
      [event]
    )
  end

  @doc """
  Delivers the queued frames in order, then waits until every event pushed while
  they were held has its reply.
  """
  def release_frames(session) do
    run_script(
      session,
      @frames <>
        """
        const held = frames.held
        frames.held = null
        for (const message of held) socket.onConnMessage(message)
        const deadline = Date.now() + 5000
        while (frames.awaiting.size > 0) {
          if (Date.now() > deadline) throw new Error("an event got no reply")
          await new Promise((resolve) => setTimeout(resolve, 50))
        }
        """
    )
  end

  @doc """
  Stops dropping frames and reconnects the LiveView socket. Returns once
  `connect()` is called; the page may then leave. Connects only after the
  disconnect's teardown: an earlier teardown still running closes the next
  connection.
  """
  def reconnect_live(session) do
    run_script(session, """
    await new Promise((resolve) => window.liveSocket.disconnect(resolve))
    if (window.frames$) window.frames$.drop = []
    window.liveSocket.connect()
    """)
  end

  @doc "Polls `fun` every 50 ms until it returns a value other than `nil`, for up to 5 s."
  def await_found(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 1 ->
        Process.sleep(50)
        await_found(fun, tries - 1)

      nil ->
        flunk("nothing was found within 5 s")

      found ->
        found
    end
  end
end
