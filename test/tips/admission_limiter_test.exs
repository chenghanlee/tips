defmodule Tips.AdmissionLimiterTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.AdmissionFixtures
  import Tips.ContentFixtures

  alias Tips.Accounts.{Scope, User}
  alias Tips.AdmissionLimiter
  alias Tips.Content.Tip

  defp scope(id), do: %Scope{user: %User{id: id}}

  defp ip(n), do: {10, 0, div(n, 256), rem(n, 256)}

  defp concurrently(count, fun) do
    1..count
    |> Task.async_stream(fun, max_concurrency: count, ordered: false)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp tally(results) do
    Enum.frequencies_by(results, fn
      :ok -> :ok
      {:error, {reason, _retry}} -> reason
      {:error, reason} -> reason
    end)
  end

  describe "budgets" do
    test "concurrent auth requests admit exactly both configured budgets" do
      %{limiter: limiter} = start_limiter(auth_destination: {5, 1_000}, auth_ip: {8, 1_000})

      # One destination from rotating IPs: the destination budget holds.
      same_destination =
        concurrently(50, &AdmissionLimiter.check_auth("victim@example.com", ip(&1), limiter))

      assert %{ok: 5, rate_limited: 45} = tally(same_destination)

      # One IP across rotating destinations: the IP budget holds.
      same_ip =
        concurrently(50, &AdmissionLimiter.check_auth("user#{&1}@example.com", ip(999), limiter))

      assert %{ok: 8, rate_limited: 42} = tally(same_ip)

      # An unrelated destination and IP are independent.
      assert :ok = AdmissionLimiter.check_auth("other@example.com", ip(1_000), limiter)
    end

    test "concurrent writes and uploads admit exactly their separate budgets" do
      %{limiter: limiter} = start_limiter(write: {7, 1_000}, upload: {3, 1_000})
      account = scope(1)

      writes = concurrently(40, fn _ -> AdmissionLimiter.check_write(account, limiter) end)
      uploads = concurrently(40, fn _ -> AdmissionLimiter.check_upload(account, limiter) end)

      assert %{ok: 7, rate_limited: 33} = tally(writes)
      assert %{ok: 3, rate_limited: 37} = tally(uploads)

      # Another account has its own budgets.
      assert :ok = AdmissionLimiter.check_write(scope(2), limiter)
      assert :ok = AdmissionLimiter.check_upload(scope(2), limiter)
    end

    test "denial consumes neither auth bucket" do
      %{limiter: limiter} = start_limiter(auth_destination: {2, 1_000}, auth_ip: {3, 1_000})

      # Exhaust the destination, then get denied from a fresh IP.
      assert :ok = AdmissionLimiter.check_auth("a@example.com", ip(1), limiter)
      assert :ok = AdmissionLimiter.check_auth("a@example.com", ip(2), limiter)

      assert {:error, {:rate_limited, _}} =
               AdmissionLimiter.check_auth("a@example.com", ip(3), limiter)

      # ip(3) kept its full budget of three.
      assert :ok = AdmissionLimiter.check_auth("b@example.com", ip(3), limiter)
      assert :ok = AdmissionLimiter.check_auth("c@example.com", ip(3), limiter)
      assert :ok = AdmissionLimiter.check_auth("d@example.com", ip(3), limiter)

      # Now ip(3) is exhausted; the denial must not consume a fresh destination.
      assert {:error, {:rate_limited, _}} =
               AdmissionLimiter.check_auth("fresh@example.com", ip(3), limiter)

      assert :ok = AdmissionLimiter.check_auth("fresh@example.com", ip(4), limiter)
      assert :ok = AdmissionLimiter.check_auth("fresh@example.com", ip(5), limiter)
    end

    test "retry feedback expires at the window boundary" do
      %{limiter: limiter, clock: clock} =
        start_limiter(auth_destination: {1, 900_000}, auth_ip: {1, 60_000})

      assert :ok = AdmissionLimiter.check_auth("a@example.com", ip(1), limiter)

      # Only the destination is blocked: retry counts down to its window end, rounded up.
      set_time(clock, 100_500)

      assert {:error, {:rate_limited, 800}} =
               AdmissionLimiter.check_auth("a@example.com", ip(2), limiter)

      set_time(clock, 899_999)

      assert {:error, {:rate_limited, 1}} =
               AdmissionLimiter.check_auth("a@example.com", ip(2), limiter)

      set_time(clock, 900_000)
      assert :ok = AdmissionLimiter.check_auth("a@example.com", ip(2), limiter)

      # Both buckets blocked: wait for the later one.
      set_time(clock, 900_000 + 30_000)

      assert {:error, {:rate_limited, 870}} =
               AdmissionLimiter.check_auth("a@example.com", ip(2), limiter)

      # Writes follow the same boundary rule.
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      assert {:error, {:rate_limited, 1}} = AdmissionLimiter.check_write(scope(1), limiter)
      advance(clock, 1_000)
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
    end
  end

  describe "storage bounds" do
    test "unique identity floods never exceed class capacity" do
      %{limiter: limiter} =
        start_limiter(
          write: {1, 1_000},
          upload: {1, 1_000},
          capacity: [auth: 6, write: 10, upload: 4]
        )

      # All three classes flood at once; each class stops at its own cap.
      results =
        concurrently(300, fn n ->
          case rem(n, 3) do
            0 -> {:auth, AdmissionLimiter.check_auth("u#{n}@example.com", ip(n), limiter)}
            1 -> {:write, AdmissionLimiter.check_write(scope(n), limiter)}
            2 -> {:upload, AdmissionLimiter.check_upload(scope(n), limiter)}
          end
        end)

      by_class = Enum.group_by(results, &elem(&1, 0), &elem(&1, 1))

      # A new auth identity needs two rows: a destination and an IP.
      assert %{ok: 3, capacity: 97} = tally(by_class.auth)
      assert %{ok: 10, capacity: 90} = tally(by_class.write)
      assert %{ok: 4, capacity: 96} = tally(by_class.upload)
      assert entry_count(limiter) == 6 + 10 + 4
    end

    test "auth saturation cannot prevent new writes or uploads" do
      %{limiter: limiter} = start_limiter(capacity: [auth: 4, write: 2, upload: 2])

      # Saturated writes and uploads leave the auth allocation untouched.
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      assert :ok = AdmissionLimiter.check_write(scope(2), limiter)
      assert :ok = AdmissionLimiter.check_upload(scope(1), limiter)
      assert :ok = AdmissionLimiter.check_upload(scope(2), limiter)
      assert {:error, {:capacity, _}} = AdmissionLimiter.check_write(scope(3), limiter)
      assert {:error, {:capacity, _}} = AdmissionLimiter.check_upload(scope(3), limiter)

      assert :ok = AdmissionLimiter.check_auth("a@example.com", ip(1), limiter)
      assert :ok = AdmissionLimiter.check_auth("b@example.com", ip(2), limiter)

      # Saturated auth leaves the write and upload allocations untouched.
      assert {:error, {:capacity, _}} =
               AdmissionLimiter.check_auth("c@example.com", ip(3), limiter)

      %{limiter: limiter} = start_limiter(capacity: [auth: 4, write: 2, upload: 2])

      for n <- 1..2,
          do: assert(:ok = AdmissionLimiter.check_auth("u#{n}@example.com", ip(n), limiter))

      assert {:error, {:capacity, _}} =
               AdmissionLimiter.check_auth("new@example.com", ip(99), limiter)

      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      assert :ok = AdmissionLimiter.check_write(scope(2), limiter)
      assert :ok = AdmissionLimiter.check_upload(scope(1), limiter)
      assert :ok = AdmissionLimiter.check_upload(scope(2), limiter)
    end

    test "existing identities with budget proceed at class capacity" do
      %{limiter: limiter} =
        start_limiter(
          auth_destination: {5, 1_000},
          write: {3, 1_000},
          capacity: [auth: 2, write: 2]
        )

      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      assert :ok = AdmissionLimiter.check_write(scope(2), limiter)
      assert {:error, {:capacity, _}} = AdmissionLimiter.check_write(scope(3), limiter)
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)

      assert :ok = AdmissionLimiter.check_auth("a@example.com", ip(1), limiter)

      assert {:error, {:capacity, _}} =
               AdmissionLimiter.check_auth("b@example.com", ip(1), limiter)

      assert :ok = AdmissionLimiter.check_auth("a@example.com", ip(1), limiter)
    end

    test "auth capacity is all-or-none across its two buckets" do
      %{limiter: limiter} = start_limiter(capacity: [auth: 3])

      assert :ok = AdmissionLimiter.check_auth("a@example.com", ip(1), limiter)
      assert :ok = AdmissionLimiter.check_auth("b@example.com", ip(1), limiter)

      # One free auth row is not enough for a new destination plus a new IP.
      assert {:error, {:capacity, _}} =
               AdmissionLimiter.check_auth("c@example.com", ip(2), limiter)

      assert entry_count(limiter) == 3
    end

    test "capacity retry uses the exhausted class expiry" do
      %{limiter: limiter, clock: clock} =
        start_limiter(write: {1, 10_000}, upload: {1, 1_000}, capacity: [write: 2])

      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      set_time(clock, 4_500)
      assert :ok = AdmissionLimiter.check_write(scope(2), limiter)
      # An upload expires sooner, but it cannot free a write row.
      assert :ok = AdmissionLimiter.check_upload(scope(1), limiter)

      set_time(clock, 5_000)
      assert {:error, {:capacity, 5}} = AdmissionLimiter.check_write(scope(3), limiter)
    end

    test "repeated capacity denials keep exact retry feedback" do
      %{limiter: limiter, clock: clock} = start_limiter(write: {1, 1_000}, capacity: [write: 2])

      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      set_time(clock, 500)
      assert :ok = AdmissionLimiter.check_write(scope(2), limiter)

      for {now, retry} <- [{600, 1}, {700, 1}, {999, 1}] do
        set_time(clock, now)
        assert {:error, {:capacity, ^retry}} = AdmissionLimiter.check_write(scope(3), limiter)
      end

      # scope(1)'s expired row is reused in place, so the table stays full.
      set_time(clock, 1_000)
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)

      # Nothing is due until scope(2) expires at 1_500.
      set_time(clock, 1_200)
      assert {:error, {:capacity, 1}} = AdmissionLimiter.check_write(scope(3), limiter)
      set_time(clock, 1_500)
      assert :ok = AdmissionLimiter.check_write(scope(3), limiter)

      # Longer windows show whole-second retry counting down to the next expiry.
      %{limiter: limiter, clock: clock} = start_limiter(write: {1, 60_000}, capacity: [write: 1])
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)

      for {now, retry} <- [{1, 60}, {30_000, 30}, {59_001, 1}] do
        set_time(clock, now)
        assert {:error, {:capacity, ^retry}} = AdmissionLimiter.check_write(scope(2), limiter)
      end

      set_time(clock, 60_000)
      assert :ok = AdmissionLimiter.check_write(scope(2), limiter)
    end

    test "expired buckets are reclaimed without refunding live buckets" do
      %{limiter: limiter, clock: clock} = start_limiter(write: {1, 1_000}, capacity: [write: 4])

      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      assert :ok = AdmissionLimiter.check_write(scope(2), limiter)
      set_time(clock, 500)
      assert :ok = AdmissionLimiter.check_write(scope(3), limiter)
      assert :ok = AdmissionLimiter.check_write(scope(4), limiter)
      assert {:error, {:capacity, 1}} = AdmissionLimiter.check_write(scope(5), limiter)

      # Capacity pressure reclaims the two expired windows only.
      set_time(clock, 1_000)
      assert :ok = AdmissionLimiter.check_write(scope(5), limiter)
      assert entry_count(limiter) == 3
      assert {:error, {:rate_limited, 1}} = AdmissionLimiter.check_write(scope(3), limiter)

      # Periodic cleanup reclaims idle expired windows without capacity pressure.
      set_time(clock, 1_500)
      run_cleanup(limiter)
      assert entry_count(limiter) == 1
      assert {:error, {:rate_limited, 1}} = AdmissionLimiter.check_write(scope(5), limiter)
    end
  end

  describe "business effects" do
    test "write consumption survives content deletion and downstream failure" do
      %{limiter: limiter} = start_limiter(write: {2, 60_000})
      user = user_fixture()

      # Representative caller: admit, then mutate. The Tip insert is a fixture
      # standing in for a future Content write; the admission path is real.
      write = fn scope, mutation ->
        with :ok <- AdmissionLimiter.check_write(scope, limiter), do: mutation.()
      end

      tip = write.(Scope.for_user(user), fn -> tip_fixture(user) end)
      Repo.delete!(tip)
      refute Repo.exists?(Tip)

      assert {:error, :provider_timeout} =
               write.(Scope.for_user(user), fn -> {:error, :provider_timeout} end)

      # No content exists, the second attempt failed downstream, and a freshly
      # built scope for the same account still sees the spent budget.
      fresh_scope = user |> Repo.reload!() |> Scope.for_user()

      assert {:error, {:rate_limited, _}} =
               write.(fresh_scope, fn -> flunk("mutation ran after denial") end)

      refute Repo.exists?(Tip)
    end
  end

  describe "instances and identity" do
    test "supervised limiter is available and isolated instances accept an injected clock" do
      supervised = Process.whereis(AdmissionLimiter)
      assert is_pid(supervised)

      assert {AdmissionLimiter, ^supervised, :worker, [AdmissionLimiter]} =
               List.keyfind(Supervisor.which_children(Tips.Supervisor), AdmissionLimiter, 0)

      assert %{
               policies: %{
                 auth_destination: {5, 900_000},
                 auth_ip: {30, 900_000},
                 write: {60, 60_000},
                 upload: {20, 600_000}
               },
               capacity: %{auth: 6_000, write: 2_000, upload: 2_000} = capacity,
               cleanup_interval_ms: 60_000
             } = :sys.get_state(supervised)

      assert capacity |> Map.values() |> Enum.sum() == 10_000

      assert :ok =
               AdmissionLimiter.check_write(scope(System.unique_integer([:positive])))

      %{limiter: limiter, clock: clock} = start_limiter(write: {1, 1_000})
      refute limiter == supervised
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
      advance(clock, 1_000)
      assert :ok = AdmissionLimiter.check_write(scope(1), limiter)
    end

    test "normalized destinations share a bucket and ETS keeps no plaintext" do
      %{limiter: limiter} = start_limiter(auth_destination: {2, 1_000}, auth_ip: {99, 1_000})

      assert :ok = AdmissionLimiter.check_auth("Alice@Example.COM", ip(1), limiter)
      assert :ok = AdmissionLimiter.check_auth("  alice@example.com\n", ip(2), limiter)

      assert {:error, {:rate_limited, _}} =
               AdmissionLimiter.check_auth("ALICE@EXAMPLE.COM", ip(3), limiter)

      stored = :ets.tab2list(:sys.get_state(limiter).table)
      refute inspect(stored, limit: :infinity) =~ ~r/alice/i
    end

    test "invalid and oversized identities are rejected without consuming budget" do
      %{limiter: limiter} = start_limiter()

      for destination <- [
            nil,
            "",
            "   ",
            "no-at-sign",
            "two@@example.com",
            "spaced out@example.com",
            String.duplicate("a", 200) <> "@example.com",
            String.duplicate(" ", 5_000) <> "a@example.com",
            <<0xFF, "a@example.com">>,
            "a@example.com" <> <<0xC3>>,
            "a\0b@example.com",
            "a\u0007@example.com",
            "a@example.com\u007F",
            :"a@example.com"
          ] do
        assert {:error, :invalid_identity} =
                 AdmissionLimiter.check_auth(destination, ip(1), limiter)
      end

      for bad_ip <- [nil, "10.0.0.1", {999, 0, 0, 1}, {10, 0, 0}, :unknown] do
        assert {:error, :invalid_identity} =
                 AdmissionLimiter.check_auth("a@example.com", bad_ip, limiter)
      end

      for bad_scope <- [
            nil,
            %Scope{user: nil},
            scope(nil),
            scope(0),
            scope("1"),
            %{user: %{id: 1}}
          ] do
        assert {:error, :invalid_identity} = AdmissionLimiter.check_write(bad_scope, limiter)
        assert {:error, :invalid_identity} = AdmissionLimiter.check_upload(bad_scope, limiter)
      end

      assert entry_count(limiter) == 0
      assert :ok = AdmissionLimiter.check_auth("a@example.com", {0, 0, 0, 0, 0, 0, 0, 1}, limiter)
    end
  end
end
