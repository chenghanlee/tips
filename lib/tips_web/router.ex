defmodule TipsWeb.Router do
  use TipsWeb, :router

  import TipsWeb.UserAuth

  @sandbox_hooks if(Application.compile_env(:tips, :sql_sandbox, false),
                   do: [TipsWeb.LiveAcceptance],
                   else: []
                 )

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TipsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TipsWeb do
    get "/healthz", HealthController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", TipsWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tips, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TipsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", TipsWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: @sandbox_hooks ++ [{TipsWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/editor/tips/new", TipLive.Editor, :new
      live "/editor/tips/:id/edit", TipLive.Editor, :edit
      live "/editor/tips/:tip_id/reviews/new", ReviewLive.Editor, :new
      live "/editor/reviews/:id/edit", ReviewLive.Editor, :edit
    end
  end

  scope "/", TipsWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: @sandbox_hooks ++ [{TipsWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new

      live "/", BrowseLive.Index, :index
      live "/search", SearchLive.Index, :index
      live "/tips/:id/:slug", TipLive.Show, :show
      live "/reviews/:id", ReviewLive.Show, :show
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
