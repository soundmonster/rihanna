defmodule Rihanna.JobTest do
  use ExUnit.Case, async: false
  import Rihanna.Job
  import TestHelper
  doctest Rihanna.Job

  @class_id Rihanna.Config.pg_advisory_lock_class_id()

  alias Rihanna.Mocks.{MockJob, MockRetriedJob}

  setup_all [:create_jobs_table]

  setup %{pg: pg} do
    Postgrex.query!(pg, "DELETE FROM rihanna_jobs;", [])
    job = insert_job(pg, :ready_to_run)
    {:ok, pg2} = Postgrex.start_link(Application.fetch_env!(:rihanna, :postgrex))

    {:ok, %{job: job, pg2: pg2}}
  end

  describe "retry_failed/1 when job has failed" do
    setup %{pg: pg} do
      failed_job = insert_job(pg, :failed)

      %{failed_job: failed_job}
    end

    test "returns {:ok, retried}", %{failed_job: failed_job} do
      assert {:ok, :retried} = retry_failed(failed_job.id)
    end

    test "nullifies failed_at and fail_reason", %{pg: pg, failed_job: failed_job} do
      retry_failed(failed_job.id)

      updated_job = get_job_by_id(pg, failed_job.id)

      assert updated_job.failed_at |> is_nil
      assert updated_job.fail_reason |> is_nil
    end

    test "resets enqueued_at", %{pg: pg, failed_job: failed_job} do
      assert {:ok, :retried} = retry_failed(failed_job.id)

      updated_job = get_job_by_id(pg, failed_job.id)

      assert DateTime.compare(failed_job.enqueued_at, updated_job.enqueued_at) == :lt
    end
  end

  describe "retry_failed/1 when job has not failed" do
    test "returns {:error, :job_not_found}", %{job: job} do
      assert {:error, :job_not_found} = retry_failed(job.id)
    end

    test "does not change job", %{pg: pg, job: job} do
      retry_failed(job.id)

      updated_job = get_job_by_id(pg, job.id)

      assert updated_job == job
    end
  end

  describe "lock/1 when job is ready to run" do
    test "returns job", %{job: %{id: id}, pg: pg} do
      assert %Rihanna.Job{id: ^id} = lock(pg)
    end

    test "takes advisory lock on first available job", %{job: %{id: id}, pg: pg, pg2: pg2} do
      assert %Rihanna.Job{id: ^id} = lock(pg)

      assert %{rows: [[false]]} =
               Postgrex.query!(pg2, "SELECT pg_try_advisory_lock(#{@class_id}, $1)", [id])
    end

    test "does not lock job if advisory lock is already taken", %{
      job: %{id: id},
      pg: pg,
      pg2: pg2
    } do
      assert %{rows: [[true]]} =
               Postgrex.query!(pg2, "SELECT pg_try_advisory_lock(#{@class_id}, $1)", [id])

      assert lock(pg) |> is_nil
    end
  end

  describe "locking order with due_at" do
    test "locks N jobs, ordered by due_at before enqueued_at, unless due_at is nil", %{pg: pg} do
      due_at2 = due_in(-5_000)
      # due_at earlier, enqueued_at after
      due_at1 = due_in(-10_000)

      Rihanna.Job.enqueue({MockJob, :arg}, %{due_at: due_at1})
      Rihanna.Job.enqueue({MockJob, :arg}, %{due_at: due_at2})

      jobs = lock(pg, 3)

      # first_job is from setup
      [first_job | jobs] = jobs
      assert is_nil(first_job.due_at)

      [second_job | jobs] = jobs
      assert due_at1 == second_job.due_at |> DateTime.truncate(:millisecond)

      [third_job | _jobs] = jobs
      assert due_at2 == third_job.due_at |> DateTime.truncate(:millisecond)
    end
  end

  describe "lock/2" do
    setup %{pg: pg, job: job} do
      jobs =
        [job] ++
          [
            insert_job(pg, :ready_to_run),
            insert_job(pg, :ready_to_run)
          ]

      {:ok, %{jobs: jobs}}
    end

    test "locks all available jobs if N is greater", %{pg: pg, jobs: jobs} do
      locked = lock(pg, 4)

      assert locked == jobs
      assert length(locked) == 3
    end

    test "locks all available jobs, ordered with the highest priority first", %{pg: pg} do
      insert_job(pg, :ready_to_run_highest_priority)
      Rihanna.Job.enqueue({MockJob, :arg}, %{priority: 15})
      # Default priority of 50
      Rihanna.Job.enqueue({MockJob, :arg}, %{priority: nil})

      [first_job | jobs] = lock(pg, 5)
      assert %Rihanna.Job{priority: 1} = first_job

      [next_job | jobs] = jobs
      assert %Rihanna.Job{priority: 15} = next_job

      # This could return any job in the table with a priority > 15
      [last_job | _jobs] = jobs
      assert %Rihanna.Job{priority: 50} = last_job
    end

    test "locks all available jobs if equal to N", %{pg: pg, jobs: jobs} do
      locked = lock(pg, 3)

      assert locked == jobs
      assert length(locked) == 3
    end

    test "locks N jobs if less than the number available", %{pg: pg, jobs: jobs} do
      locked = lock(pg, 2)
      locked_set = locked |> MapSet.new()
      jobs_set = jobs |> MapSet.new()

      assert MapSet.subset?(locked_set, jobs_set)
      assert length(locked) == 2
    end

    test "skips jobs that are locked by another session", %{job: job, pg: pg, pg2: pg2} do
      %{rows: [[true]]} =
        Postgrex.query!(pg2, "SELECT pg_try_advisory_lock(#{@class_id}, $1)", [job.id])

      locked = lock(pg, 3)
      assert length(locked) == 2
      refute Enum.any?(locked, fn %{id: id} -> id == job.id end)
    end

    test "skips jobs that are already locked by this session", %{job: job, pg: pg} do
      locked = lock(pg, 3, [job.id])
      assert length(locked) == 2
      refute Enum.any?(locked, fn %{id: id} -> id == job.id end)
    end

    # This simulates the row-locks that occur when a job has been deleted after the
    # SELECT query already took it's MVCC snapshot. It's important to skip these
    # locked jobs since in a pure sense they no longer exist.
    test "skips jobs that are row-locked by another session", %{job: job, pg: pg, pg2: pg2} do
      Postgrex.query!(pg2, "BEGIN", [])
      Postgrex.query!(pg2, "SELECT id FROM rihanna_jobs WHERE id = $1 FOR UPDATE", [job.id])

      locked = lock(pg, 3)
      assert length(locked) == 2
      refute Enum.any?(locked, fn %{id: id} -> id == job.id end)

      Postgrex.query!(pg2, "ROLLBACK", [])
    end

    test "returns empty list if n = 0", %{pg: pg} do
      assert lock(pg, 0) == []
    end
  end

  describe "mark_successful" do
    setup %{pg: pg, job: %{id: id}} do
      %{num_rows: 1} = Postgrex.query!(pg, "SELECT pg_advisory_lock(#{@class_id}, $1)", [id])
      :ok
    end

    test "deletes job if exists", %{pg: pg, job: job} do
      assert {:ok, 1} = mark_successful(pg, job)

      assert get_job_by_id(pg, job.id) |> is_nil
    end

    test "releases lock", %{pg: pg, job: job} do
      %{num_rows: 1} =
        Postgrex.query!(
          pg,
          """
            SELECT objid AS id
            FROM pg_locks pl
            WHERE locktype = 'advisory'
            AND pl.pid = pg_backend_pid()
            AND classid = #{@class_id}
            AND objid = $1
          """,
          [job.id]
        )

      assert {:ok, 1} = mark_successful(pg, job)

      assert %{num_rows: 0} =
               Postgrex.query!(
                 pg,
                 """
                   SELECT objid AS id
                   FROM pg_locks pl
                   WHERE locktype = 'advisory'
                   AND pl.pid = pg_backend_pid()
                   AND classid = #{@class_id}
                   AND objid = $1
                 """,
                 [job.id]
               )
    end

    test "does nothing if job does not exist", %{pg: pg, job: job} do
      %{num_rows: 1} =
        Postgrex.query!(
          pg,
          """
            DELETE FROM rihanna_jobs WHERE id = $1
          """,
          [job.id]
        )

      assert {:ok, 0} = mark_successful(pg, job)
    end
  end

  describe "mark_failed/3" do
    test "sets failed_at and reason", %{pg: pg} do
      job = insert_job(pg, :ready_to_run)

      %{rows: [[true]]} =
        Postgrex.query!(pg, "SELECT pg_try_advisory_lock(#{@class_id}, $1)", [job.id])

      now = DateTime.utc_now()
      reason = "It went kaboom!"

      mark_failed(pg, job, now, reason)

      updated_job = get_job_by_id(pg, job.id)

      assert updated_job.failed_at == now
      assert updated_job.fail_reason == "It went kaboom!"
    end
  end

  describe "mark_retried/3" do
    test "increments the rihanna_internal_meta attempts field and sets due_at", %{pg: pg} do
      job = insert_job(pg, :ready_to_run)

      %{rows: [[true]]} =
        Postgrex.query!(pg, "SELECT pg_try_advisory_lock(#{@class_id}, $1)", [job.id])

      due_at = DateTime.utc_now()

      mark_retried(pg, job, due_at)

      updated_job = get_job_by_id(pg, job.id)

      assert updated_job.due_at == due_at
      assert updated_job.rihanna_internal_meta["attempts"] == 1
    end
  end

  describe "mark_reenqueued/3" do
    test "retains the rihanna_internal_meta field and sets due_at", %{pg: pg} do
      attempt_count = 2
      job = insert_job(pg, :retried, attempt_count)

      %{rows: [[true]]} =
        Postgrex.query!(pg, "SELECT pg_try_advisory_lock(#{@class_id}, $1)", [job.id])

      due_at = due_in(30_000)

      mark_reenqueued(pg, job, due_at)

      updated_job = get_job_by_id(pg, job.id)

      assert is_nil(updated_job.failed_at)
      assert updated_job.due_at |> DateTime.truncate(:millisecond) == due_at
      assert updated_job.rihanna_internal_meta["attempts"] == attempt_count
    end
  end

  describe "retry_at/4" do
    test "returns :noop when job module does not define retry_at function" do
      assert :noop == Rihanna.Job.retry_at(MockJob, nil, nil, nil)
    end

    test "returns {:ok, %DateTime{}} when job module defines retry_at" do
      {:ok, %DateTime{}} = Rihanna.Job.retry_at(MockRetriedJob, "", [], 0)
    end
  end

  describe "`enqueue/3` with priority option" do
    test "includes the priority", %{pg: pg} do
      {:ok, job} = Rihanna.Job.enqueue({MockJob, :arg}, %{priority: 2})

      job = get_job_by_id(pg, job.id)

      assert job.priority == 2
    end
  end
end
