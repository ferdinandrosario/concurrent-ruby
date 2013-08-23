require 'thread'
require 'functional'

behavior_info(:runnable,
              run: 0,
              stop: 0,
              running?: 0)

module Concurrent

  class Supervisor

    behavior(:runnable)

    DEFAULT_MONITOR_INTERVAL = 1
    RESTART_STRATEGIES = [:one_for_one, :one_for_all, :rest_for_one]
    DEFAULT_MAX_RESTART = 5
    DEFAULT_MAX_TIME = 60

    WorkerContext = Struct.new(:worker, :thread)

    attr_reader :monitor_interval
    attr_reader :restart_strategy
    attr_reader :max_restart
    attr_reader :max_time

    alias_method :strategy, :restart_strategy
    alias_method :max_r, :max_restart
    alias_method :max_t, :max_time

    def initialize(opts = {})
      @restart_strategy = opts[:restart_strategy] || opts[:strategy] || :one_for_one
      @monitor_interval = (opts[:monitor_interval] || DEFAULT_MONITOR_INTERVAL).to_f

      raise ArgumentError.new(':monitor_interval must be greater than zero') unless @monitor_interval > 0.0
      raise ArgumentError.new(":#{@restart_strategy} is not a valid restart strategy") unless RESTART_STRATEGIES.include?(@restart_strategy)

      @mutex = Mutex.new
      @workers = []
      @running = false

      @monitor = nil

      add_worker(opts[:worker]) unless opts[:worker].nil?
    end

    def run!
      raise StandardError.new('already running') if running?
      @mutex.synchronize do
        @running = true
        @monitor = Thread.new{ monitor }
        @monitor.abort_on_exception = false
      end
      Thread.pass
    end

    def run
      raise StandardError.new('already running') if running?
      @running = true
      monitor
    end

    def stop
      return true unless running?
      @running = false
      @mutex.synchronize do
        Thread.kill(@monitor) unless @monitor.nil?
        @monitor = nil

        @workers.length.times do |i|
          context = @workers[-1-i]
          begin
            context.worker.stop
            Thread.pass
          rescue Exception => ex
            # suppress
          ensure
            Thread.kill(context.thread) unless context.thread.nil?
          end
        end
      end
    end

    def running?
      return @running
    end

    def length
      return @workers.length
    end
    alias_method :size, :length

    def add_worker(worker)
      if worker.nil? || running? || ! worker.behaves_as?(:runnable)
        return false
      else
        @mutex.synchronize {
          @workers << WorkerContext.new(worker)
        }
        return true
      end
    end

    private

    def monitor
      loop do
        @mutex.synchronize do
          self.send(@restart_strategy)
        end
        break unless running?
        sleep(@monitor_interval)
        break unless running?
      end
    end

    def one_for_one
      @workers.each do |context|
        unless context.thread && context.thread.alive?
          context.thread = Thread.new{ context.worker.run }
          context.thread.abort_on_exception = false
        end
      end
    end

    def one_for_all
      restart = false

      restart = @workers.each do |context|
        unless context.thread && context.thread.alive?
          break(true)
        end
      end

      if restart

        @workers.each do |context|
          begin
            context.worker.stop
          rescue Exception => ex
            # suppress
          end
        end

        @workers.each do |context|
          context.thread = Thread.new{ context.worker.run }
          context.thread.abort_on_exception = false
        end
      end
    end

    def rest_for_one
      restart = false

      @workers.each do |context|
        if restart
          begin
            context.worker.stop
          rescue Exception => ex
            # suppress
          end
        elsif ! context.thread || ! context.thread.alive?
          restart = true
        end
      end

      one_for_one if restart
    end
  end
end