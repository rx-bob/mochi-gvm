module OtherData
  BASE = 99
  def self.base
    BASE
  end
end
module RecordData
  BASE = 7
  def self.base
    BASE
  end
  def self.build
    kept = []
    total = 0
    [1, 2, 3].each do |item|
      next if item == 2
      total += item
      kept << item
    end
    mapped = [1, 2, 3].map do |item|
      next BASE if item == 2
      item + 10
    end
    kept.join(',') + ':' + mapped.join(',') + ':' + total.to_s + ':after'
  end
  def self.nested
    total = 0
    [1, 2].each do |outer|
      [1, 2, 3].each do |inner|
        next if inner == 2
        total += outer * inner
      end
    end
    total
  end
end
class HelperRoot
  def constants
    [RecordData::BASE, RecordData.base, OtherData::BASE, OtherData.base].join(',')
  end
  def blocks
    RecordData.build
  end
  def nested
    RecordData.nested
  end
  def missing_constant
    RecordData::MISSING
  end
  def missing_method
    RecordData.missing
  end
end
