require 'spec_helper'

describe Orchestrator::Matrix do
  let(:matrix) {Orchestrator::Matrix}
  before(:each) do
    Orchestrator::Matrix.clear!
    Orchestrator.map_queue_weights \
      A: 40,
      B: 30,
      C: 20,
      D: 10
  end

  describe "#queues_for!" do
    context "with no rows" do
      it "should generate new rows" do
        result = matrix.queues_for!('host1', 1)
        result.should == [[:A, :B, :C, :D]]
      end

      it "should populate the persistant model" do
        result = matrix.queues_for!('host1', 1)
        result.should == matrix.to_table
      end
    end

    context "with existing rows" do
      it "should maintain existing rows if no more needed" do
        matrix.queues_for!('host1', 1)
        matrix.queues_for!('host1', 1)
        matrix.fetch.size.should == 1
      end

      it "should add rows if more needed" do
        matrix.queues_for!('host1', 1)
        matrix.queues_for!('host1', 2)
        matrix.fetch.size.should == 2
      end

      it "should prune rows if less are needed" do
        matrix.queues_for!('host1', 2)
        matrix.queues_for!('host1', 1)
        matrix.fetch.size.should == 1
      end
    end

    context "with multiple hosts" do
      before do
        matrix.queues_for!('host1', 2)
        matrix.queues_for!('host2', 2)
      end

      let(:host1_rows) {matrix.fetch.select{|row| row.hostname == 'host1'}}
      let(:host2_rows) {matrix.fetch.select{|row| row.hostname == 'host2'}}

      context "when rows are added" do
        it "should associate them with the specific host" do
          matrix.queues_for!('host1', 3)
          host1_rows.size.should == 3
          host2_rows.size.should == 2
        end
      end

      context "when rows are pruned" do
        it "should prune them from the specific host" do
          matrix.queues_for!('host2', 1)
          host1_rows.size.should == 2
          host2_rows.size.should == 1
        end
      end
    end
  end
end
