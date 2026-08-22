require "tsort"

module CustomFields
  class DirectedGraph
    include TSort

    def initialize
      @successors = {}
    end

    def add_node(node)
      @successors[node] ||= []
      self
    end

    def add_edge(from, to)
      add_node(from)
      add_node(to)
      @successors[from] << to
      self
    end

    def topological_order
      strongly_connected_components.flatten(1)
    end

    def break_cycles
      strongly_connected_components.each do |component|
        yield component if component.size > 1 || @successors[component.first].include?(component.first)
      end
      self
    end

    private

    def tsort_each_node(&block)
      @successors.each_key(&block)
    end

    def tsort_each_child(node, &block)
      @successors[node].each(&block)
    end
  end
end
