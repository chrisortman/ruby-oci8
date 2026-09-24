# High-level API
require 'oci8'
require 'timeout'
require File.dirname(__FILE__) + '/config'

class TestBreak < Minitest::Test

  def setup
    @conn = get_oci8_connection
    Thread.report_on_exception, @original_report_on_exception = false, Thread.report_on_exception if Thread.respond_to?(:report_on_exception)
  end

  def teardown
    @conn.logoff
    Thread.report_on_exception = @original_report_on_exception if Thread.respond_to?(:report_on_exception)
  end

  def report(str)
    printf "%d: %s\n", (Time.now - $start_time), str
  end

  @@server_is_runing_on_windows = nil
  def server_is_runing_on_windows?
    if @@server_is_runing_on_windows.nil?
      @conn.exec('select dbms_utility.port_string from dual') do |row|
        @@server_is_runing_on_windows = row[0].include? '/WIN'
      end
    end
    @@server_is_runing_on_windows
  end

  PLSQL_DONE = 1
  OCIBREAK = 2
  SEND_BREAK = 3

  TIME_IN_PLSQL = 5
  TIME_TO_BREAK = 2

  def do_test_ocibreak(conn, expect)
    $start_time = Time.now

    th = Thread.start do 
      begin
        conn.exec("BEGIN DBMS_LOCK.SLEEP(#{TIME_IN_PLSQL}); END;")
        assert_equal(expect[PLSQL_DONE], (Time.now - $start_time).round, 'PLSQL_DONE')
      rescue OCIBreak
        assert_equal(expect[OCIBREAK], (Time.now - $start_time).round, 'OCIBREAK')
        assert_equal('Canceled by user request.', $!.to_s)
      end
    end

    sleep(0.3) # Wait until DBMS_LOCK.SLEEP is running.
    sleep(TIME_TO_BREAK - 0.3)
    assert_equal(expect[SEND_BREAK], (Time.now - $start_time).round, 'SEND_BREAK')
    conn.break()
    th.join
  end

  def test_blocking_mode
    @conn.non_blocking = false
    assert_equal(false, @conn.non_blocking?)
    expect = []
    expect[PLSQL_DONE] = TIME_IN_PLSQL
    expect[OCIBREAK]   = "Invalid status"
    if (defined? Rubinius and Rubinius::VERSION >= "2.0") || (defined? RUBY_ENGINE and RUBY_ENGINE == "truffleruby")
      # Rubinius 2.0.0.
      # DBMS_LOCK.SLEEP blocks ruby threads which try to call C-API.
      expect[SEND_BREAK] = TIME_TO_BREAK
    else
      # MRI and Rubinius 1.2.4.
      # DBMS_LOCK.SLEEP blocks all ruby threads.
      expect[SEND_BREAK] = TIME_IN_PLSQL + TIME_TO_BREAK
    end
    do_test_ocibreak(@conn, expect)
  end

  def test_non_blocking_mode
    @conn.non_blocking = true
    assert_equal(true, @conn.non_blocking?)
    expect = []
    if server_is_runing_on_windows?
      if $oracle_server_version >= OCI8::ORAVER_9_0
        # raise after sleeping #{TIME_IN_PLSQL} seconds.
        expect[PLSQL_DONE] = "Invalid status"
        expect[OCIBREAK] = TIME_IN_PLSQL
      else
        expect[PLSQL_DONE] = TIME_IN_PLSQL
        expect[OCIBREAK] = "Invalid status"
      end
    else
      # raise immediately by OCI8#break.
      expect[PLSQL_DONE] = "Invalid status"
      expect[OCIBREAK] = TIME_TO_BREAK
    end
    expect[SEND_BREAK]   = TIME_TO_BREAK
    do_test_ocibreak(@conn, expect)
  end

  def test_signal_trap_does_not_break
    skip 'SIGUSR1 is not available' unless Signal.list.key?('USR1')
    @conn.non_blocking = true
    trapped = false
    previous_trap = trap('USR1') { trapped = true }
    Thread.new { sleep 0.5; Process.kill('USR1', Process.pid) }
    # Long enough to be running when the signal arrives.
    rows = "(SELECT level l FROM dual CONNECT BY level <= 3000)"
    count = @conn.select_one("SELECT COUNT(*) FROM #{rows} a, #{rows} b, (SELECT level l FROM dual CONNECT BY level <= 10) c")[0]
    assert_equal(90_000_000, count)
    assert(trapped)
  ensure
    trap('USR1', previous_trap || 'DEFAULT')
  end

  def test_timeout
    @conn.non_blocking = true
    start_time = Time.now
    if server_is_runing_on_windows?
      end_time = start_time + 5
    else
      end_time = start_time + 1
    end

    if defined? Rubinius and Rubinius::VERSION < "2.0"
      # Rubinius 1.2.4
      expected = OCIBreak
    else
      # MRI and Rubinius 2.0.0
      expected = Timeout::Error
    end
    assert_raises(expected) do
      Timeout.timeout(1) do
        @conn.exec("BEGIN DBMS_LOCK.SLEEP(5); END;")
      end
    end
    assert_in_delta(Time.now, end_time, 1)
    sleep(0.01) # for truffleruby. Is truffleruby too fast?
    @conn.exec("BEGIN NULL; END;")
    assert_in_delta(Time.now, end_time, 1)
  end
end
