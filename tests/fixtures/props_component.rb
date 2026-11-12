class PropsComponent
  def __mochi_apply_props(props, initial)
    if props.key?("label")
      @label = props["label"]
    elsif initial
      @label = "default"
    end
    if props.key?("count")
      @count = props["count"]
    elsif initial
      @count = 3
    end
    if props.key?("flag")
      @flag = props["flag"]
    elsif initial
      @flag = false
    end
    if props.key?("note")
      @note = props["note"]
    elsif initial
      @note = nil
    end
    if props.key?("rows")
      @rows = props["rows"]
    elsif initial
      @rows = []
    end
    if props.key?("meta")
      @meta = props["meta"]
    elsif initial
      @meta = {}
    end
    nil
  end

  def initialize
    @init_label = @label
    @init_count = @count
    @init_note = @note
    @label = "clobbered"
    @count = 999
    @rows = ["clobbered"]
  end

  def label
    @label
  end

  def count
    @count
  end

  def flag
    @flag
  end

  def note
    @note
  end

  def rows
    @rows
  end

  def meta
    @meta
  end

  def init_label
    @init_label
  end

  def init_count
    @init_count
  end

  def init_note
    @init_note
  end
end
