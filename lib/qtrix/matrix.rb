require 'bigdecimal'
require 'qtrix/matrix/model'
require 'qtrix/matrix/queue_picker'
require 'qtrix/matrix/row_builder'
require 'qtrix/matrix/queue_prioritizer'
require 'qtrix/matrix/analyzer'

module Qtrix
  ##
  # Represents the matrix of queues to workers across the global worker pool,
  # and is used to assign queues to pools based on the following goals:
  #
  # 1.  Maintain a desired distribution of worker resources to queues based
  #     on their weight within the system as a whole.
  # 2.  Ensure that every queue is at the head of at least 1 workers queue
  #     list.
  #
  # Given a queue's weight, we calculate its resource percentage as:
  #
  # weight_of(queue) / weight_of(all_queues)
  #
  # To generate the list of queues for a worker, we take a list of queues
  # sorted by current priority.  The current priority is calculated in one of
  # two ways.  If the queue has not been at the head of the list, it is
  # calculated as:
  #
  # relative_weight(queue) * 1000
  #
  # This inflated value ensures that we will assign all queues to the head of
  # at least one worker's queue list.
  #
  # If a queue has not been assigned to the head of a worker's queue list,
  # the following algortihm is used.  Each entry in the matrix has a value,
  # which is generally the likelihood that the queue would be reached given
  # the weight of jobs to its left in a queue list.  Mathematically, this is:
  #
  # 1.0 - relative_weight(previous_queues_in_list)
  #
  # Thus the closer to the head of a list a queue's entry is, the higher a
  # value it receives for that entry.  The priority is then calculated as:
  #
  # relative_weight(queue) / (1.0 + value_of(entries_for(queue))
  #
  # This ensures that the higher a queue appears in a list, the lower its
  # priority for the next generated list.

  class Matrix
    include Logging
    REDIS_KEY = :matrix

    def initialize(redis)
      @redis = redis
    end

    ##
    # Obtain lists of queues for a number of worker processes
    # on a server identified by the hostname.
    # Saves changes back to redis
    def update_matrix_to_satisfy_request!(hostname, num_rows_requested)
      matrix = fetch
      queue_picker = QueuePicker.new(matrix, Qtrix.desired_distribution)
      requested_rows = queue_picker.modify_matrix_to_satisfy_request(hostname, num_rows_requested)

      matrix.added_rows.each{|row| redis.rpush(REDIS_KEY, pack(row))}
      matrix.deleted_rows.each{|row| redis.lrem(REDIS_KEY, -1, pack(row))}
      requested_rows
    end

    ##
    # Returns all of the queues in the table.
    def fetch
      Model.new(@redis.lrange(REDIS_KEY, 0, -1).map{|dump| unpack(dump)})
    end

    ##
    # Clears the matrix so its rebuilt again when rows are requested.
    def clear!
      debug("what if I told you I was clearing the matrix?")
      redis.del(REDIS_KEY)
    end

    private

    attr_reader :redis

    def pack(item)
      # Marshal is fast but not human readable, might want to
      # go for json or yaml. This is fast at least.
      Marshal.dump(item)
    end

    def unpack(item)
      Marshal.restore(item)
    end
  end
end

