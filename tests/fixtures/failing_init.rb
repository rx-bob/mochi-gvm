class FailingInit
  @tag_name = "failing-init"

  def initialize
    missing_helper
  end

  def html
    %Q{<span>never mounted</span>}
  end
end
