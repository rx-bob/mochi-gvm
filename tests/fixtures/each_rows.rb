class EachRows

  def initialize
    @items = [
      {"id" => "a", "label" => "Alpha"},
      {"id" => "b", "label" => "Beta"}
    ]
    @children = ["a1", "a2"]
    @status = "idle"
    @suffix = "!"
  end

  def label(item, index)
    item["label"] + @suffix + ":" + index.to_s
  end

  def __mochi_each_0_rows
    rows = []
    (@items || []).each_with_index do |item, index|
      child_rows = []
      (@children || []).each_with_index do |child, ci|
        child_rows.push([child, [child + "#" + index.to_s], []])
      end
      rows.push([item, [item["id"], label(item, index)], [child_rows]])
    end
    rows
  end

  def __mochi_each_1_rows
    rows = []
    @items.each_with_index do |item, index|
      rows.push([item, [broken(item)], []])
    end
    rows
  end

  def __mochi_each_0_ev_1(scope_item, scope_index, __event)
    open_event(scope_index)
  end

  def open_event(index)
    @status = index.to_s
  end

  def broken(item)
    item.no_such_method
  end

  def bump
    @suffix = "?"
  end

  def status
    @status
  end
end
