require 'qtrix/version'
require 'qtrix/logging'
require 'qtrix/persistence'
require 'qtrix/queue_store'
require 'qtrix/override_store'
require 'qtrix/queue'
require 'qtrix/override'
require 'qtrix/matrix'
require 'qtrix/host_manager'
require 'qtrix/locking'

##
# Facade into a dynamically adjusting global worker pool that auto
# balances workers according to a desired distribution of resources
# for each queue.
#
# The desired distribution can be modified in real time, and the
# workers throughout our global pool across all servers should morph
# to reflect the new desired distribution.  Further details on how
# desired distribution is achieved can be found in the
# lib/qtrix/matrix.rb comments.
#
# Overrides should be able to be specified, so that we can say
# out of all of our workers, N should specifically service this list
# of queues.  This is for flood event handling -- a queue gets flooded
# and we need to direct resources to it to help process the jobs faster.
#
# This is the primary entry point to the system, a GUI, CLI or script
# meant to interact with the system should probably work through this
# module

module Qtrix
  extend Logging
  ##
  # Specifies the redis connection configuration options as per the
  # redis gem.

  def self.connection_config(opts={})
    Persistence.connection_config(opts)
  end

  ##
  # Returns the public operations of the facade.  Useful when tinkering
  # in a REPL.
  def self.operations
    self.public_methods - Module.public_methods
  end

  ##
  # Returns a list of objects that define the desired distribution
  # of workers.  Each element will contain the queue name, weight, and
  # relative_weight (weight / total weight of all queues).

  def self.desired_distribution
    queue_store.all_queues
  end

  ##
  # Specifies the queue/weight mapping table.
  # This will be used to generate the queue list for workers and thus the
  # desired distribution of resources to queues.  Args can be:
  #
  # map: the queue-to-weight mappings as a hash of queue names to
  #      float values.

  def self.map_queue_weights(map)
    with_lock do
      queue_store.map_queue_weights(map)
    end
  rescue Exception => e
    error(e)
    raise
  end

  ##
  # Add a list of queue names to use as an override for a number
  # of worker processes.  The number of worker processes will be removed from
  # the desired distribution and start working the list of queues in the
  # verride. args should be:
  #
  # queues:  Array of queue names.
  # processes:  Integer specifying the number of workers
  # to override queues for.

  def self.add_override(*args)
    with_lock do
      queues, processes = *args
      override_store.add(queues, processes)
      true
    end
  rescue Exception => e
    error(e)
    raise
  end

  ##
  # Removes an override.
  # That number of worker processes will quit servicing the queues in the
  # override and be brought back into servicing the desired distribution.
  # Args can be:
  #
  # queues:  Array of queues in the override.
  # processes:  Number of processes to remove from overriding.

  def self.remove_override(*args)
    with_lock do
      queues, processes = *args
      override_store.remove(queues, processes)
      true
    end
  rescue Exception => e
    error(e)
    raise
  end

  ##
  # Retrieves all currently defined overrides.

  def self.overrides
    override_store.all
  end

  def self.redis
    @redis ||= Persistence.redis
  end

  def self.host_manager
    @host_manager ||= HostManager.new(redis)
  end

  def self.queue_store
    @queue_store ||= QueueStore.new(redis)
  end

  def self.locker
    @locker ||= Qtrix::Locking.new(redis)
  end

  def self.matrix_store
    @matrix_store ||= Qtrix::Matrix.new(redis)
  end

  def self.override_store
    @override_store ||= Qtrix::OverrideStore.new(redis, matrix_store)
  end

  def self.with_lock(*args, &block)
    locker.with_lock(*args, &block)
  end

  ##
  # Retrieves lists of queues as appropriate to the overall system balance
  # for the number of workers specified for the given +hostname+.

  def self.fetch_queues(hostname, workers, opts={})
    host_manager.ping(hostname)
    clear_matrix_if_any_hosts_offline
    with_lock timeout: opts.fetch(:timeout, 5), on_timeout: last_result do
      debug("fetching #{workers} queue lists for #{hostname}")
      overrides_queues = override_store.overrides_for(hostname, workers)
      debug("overrides for #{hostname}: #{overrides_queues}")
      delta = workers - overrides_queues.size
      matrix_queues = delta > 0 ? matrix_store.fetch_queues(hostname, delta) : []
      debug("matrix queue lists: #{matrix_queues}")
      new_result = overrides_queues + matrix_queues.map(&append_orchestrated_flag)
      info("queue lists changed") if new_result != @last_result
      debug("list details: #{new_result}")
      @last_result = new_result
    end
  rescue Exception => e
    error(e)
    raise
  end

  ##
  # Clears redis of all information related to the orchestration system
  def self.clear!
    with_lock do
      info "clearing data"
      override_store.clear_claims!
      host_manager.clear!
      matrix_store.clear!
    end
  end

  private

  def self.last_result
    lambda do
      if @last_result
        @last_result
      else
        raise "no previous result (unable to obtain lock on first attempt)"
      end
    end
  end

  def self.clear_matrix_if_any_hosts_offline
    if host_manager.any_offline?
      info "hosts detected offline: #{host_manager.offline.join(', ')}"
      clear!
    end
  end

  def self.append_orchestrated_flag
    lambda {|queue_lists| queue_lists << :__orchestrated__}
  end

  class ConfigurationError < StandardError; end
end
