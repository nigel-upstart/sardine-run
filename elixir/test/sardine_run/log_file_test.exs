defmodule SardineRun.LogFileTest do
  use ExUnit.Case, async: true

  alias SardineRun.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/sardine-run.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/sardine-run-logs") == "/tmp/sardine-run-logs/log/sardine-run.log"
  end
end
