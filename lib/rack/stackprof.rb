require 'stackprof'
require 'rack/stackprof/version'

class Rack::Stackprof
  # @param [Rack::Application] app
  # @param [Hash] options
  # @option options [Integer] :profile_interval_seconds
  # @option options [Integer] :sampling_interval_microseconds
  # @option options [String] :result_directory The directory to save the profiling results.
  # @option options [String] :profile_include_path
  #   Request paths to save profile. If this option is not nil nor empty,
  #   requests only matching the path are profiled.
  #   This is must be String which is valid as a Regexp, or Regexp
  # @param [Hash] stackprof_options
  def initialize(app, options = {}, stackprof_options = {})
    @app = app
    @profile_interval_seconds = options.fetch(:profile_interval_seconds)
    @sampling_interval_microseconds = options.fetch(:sampling_interval_microseconds)
    @last_profiled_at = nil
    include_path = options.fetch(:profile_include_path)
    @profile_include_path = case include_path
                            when Regexp
                              include_path
                            when String
                              if !include_path.empty?
                                Regexp.compile(include_path)
                              end
                            end
    @stackprof_options = {mode: :wall, interval: @sampling_interval_microseconds}.merge(stackprof_options)
    StackProf::Middleware.path = options.fetch(:result_directory) # for `StackProf::Middleware.save`
  end

  def call(env)
    # Profile every X seconds (not everytime) to prevent from consuming disk excessively
    profile_every(seconds: @profile_interval_seconds, env: env) do
      @app.call(env)
    end
  end

  private

  def profile_every(seconds:, env:, &block)
    if should_profile?(env) && (@last_profiled_at.nil? || @last_profiled_at < Time.now - seconds)
      @last_profiled_at = Time.now
      with_profile(env) { block.call }
    else
      block.call
    end
  end

  def should_profile?(env)
    @profile_include_path.nil? || env['PATH_INFO'].match(@profile_include_path)
  end

  def with_profile(env)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_microsecond)
    StackProf.start(@stackprof_options)
    yield
  ensure
    StackProf.stop
    finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_microsecond)

    filename = result_filename(env: env, duration_milliseconds: (finished_at - started_at) / 1000)
    StackProf::Middleware.save(filename)
  end

  # ex: "stackprof-20171004_175816-41860-GET_v1_users-0308ms.dump"
  def result_filename(env:, duration_milliseconds:)
    "stackprof-#{Time.now.strftime('%Y%m%d_%H%M%S')}-#{Process.pid}-#{env['REQUEST_METHOD']}#{env['REQUEST_PATH'].gsub(/[^\w]/, '_')}-#{'%04d' % duration_milliseconds.to_i}ms.dump"
  end
end
