class GemUser
  def initialize
    @answer = SampleGem.ruby_answer
  end

  def html
    "<span>#{@answer}</span>"
  end
end
