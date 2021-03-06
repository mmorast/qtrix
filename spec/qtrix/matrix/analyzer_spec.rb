require 'spec_helper'

describe Qtrix::Matrix::Analyzer do
  before(:each) do
    Qtrix.map_queue_weights A: 40, B: 30, C: 20, D: 10
  end
  let(:matrix) {Qtrix::Matrix.new(redis).update_matrix_to_satisfy_request!("host1", 4)}

  describe "#breakdown" do
    it "returns a hash with queue name keys that reference counts by column" do
      result = Qtrix::Matrix::Analyzer.breakdown(matrix)
      result.should == {
        A: [1,3,0,0],
        B: [1,1,2,0],
        C: [1,0,2,1],
        D: [1,0,0,3]
      }
    end
  end

  describe "#analyze!" do
    it "should map queue weights, populate matrix then break it down." do
      expected = {
        A: [1,3,0,0],
        B: [1,1,2,0],
        C: [1,0,2,1],
        D: [1,0,0,3]
      }
      result = Qtrix::Matrix::Analyzer.analyze! 4, \
        A: 40,
        B: 30,
        C: 20,
        D: 10
      result.should == expected
    end
  end
end
