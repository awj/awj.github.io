#!/usr/bin/env ruby

# Allow us to efficiently answer questions about a large amount of data based on
# specific column(s) in it.
class Index
  # Create and return a new empty `Index` responsible for fast access for the
  # provided list of columns.
  def self.declare(*columns)
    # All we need to do to "start" things is create an `Index` object to handle
    # the very first column provided. It will take care of creating `Index`
    # objects to handle the rest of the columns.
    Index.new(columns[0], columns.drop(1))
  end
  # The column this index is handling.
  attr_reader :column

  # The columns that come *after* this one in the index. If this list is empty,
  # we're at the "end" of the index column list and should instead be providing
  # values.
  attr_reader :subsequent_columns

  # The actual index content. I'm avoiding calling this `data` because it's
  # *not* the actual data we're indexing. Confusing terminology.
  attr_reader :content

  # Generate an index to represent `column`. That index will either store values
  # for actual row ids (if `subsequent_columns` is empty), or it will store
  # other `Index` objects that represent the subsequent columns.
  def initialize(column, subsequent_columns = [])
    @column = column
    @subsequent_columns = subsequent_columns
    @content = {}
  end

  # Are we the final column of the index? If so, our answers should be data id
  # values instead of another `Index`
  def leaf?
    @subsequent_columns.empty?
  end

  # "Index" a piece of data. It's assumed that this data is functionally a Hash
  # that contains at least an `"id"` key, and whatever value we have for `column`.
  def add(data)
    value = data[column]
    if leaf?
      @content[value] = data["id"]
    else
      # If we are *not* the final column, create a new Index to represent the
      # data that all shares the same value for our `column`. This index should
      # use the *next* subsequent column, and needs to know about the *rest* of
      # the subsequent columns in case it too is not the final one.
      @content[value] ||= Index.new(subsequent_columns[0], subsequent_columns.drop(1))
      @content[value].add(data)
    end
  end
end
