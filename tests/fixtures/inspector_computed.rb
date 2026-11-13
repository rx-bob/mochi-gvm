# Default-profile regression for 480 durable records and shared projections.
module RecordData
  BASE = 1794571200000
  COUNT = 480
  PAGE_SIZE = 12

  def self.base_ms
    BASE
  end

  def self.record(index)
    {
      "id" => "record-#{index}",
      "severity" => index % 3 == 0 ? "warning" : "info",
      "message" => "Record #{index} processed",
      "details" => {"source" => "worker-#{index % 4}", "sequence" => index,
                    "timestamp" => BASE + index,
                    "attributes" => [{"name" => "region", "value" => "zone-#{index % 3}"},
                                     {"name" => "attempt", "value" => index % 5 + 1}]}
    }
  end

  def self.filter(records, query)
    matches = []
    records.each do |record|
      next if !record["message"].include?(query)
      matches << record
    end
    matches
  end

  def self.find(records, id)
    found = nil
    records.each { |record| found = record if record["id"] == id }
    found
  end
end

class InspectorComputed
  __mochi_computed(:filtered, [:@records, :@query])
  __mochi_computed(:visible, [:@records, :@query, :@page])

  def initialize
    @records = []
    index = 1
    while index <= RecordData::COUNT
      @records << RecordData.record(index)
      index += 1
    end
    @query = ""
    @page = 0
  end

  def filtered
    RecordData.filter(@records, @query)
  end

  def visible
    filtered.slice(@page * 12, 12)
  end

  def next_page
    @page += 1
  end
end
