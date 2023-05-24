---
layout: post
title:  "Understanding database indices by (poorly) implementing one"
date:   2023-05-20 13:59:12 -0700
categories: [ruby, databases, performance]
excerpt: >-
    Or: building an intuition for how databases use indices
---

There's a lot of misconceptions about database indices. These exist, in part, because people are missing the context needed to imagine how a database uses them. There's *a lot* to learn to establish that context. Too much for one blog post. But, we can try to bootstrap off what's already familiar to help develop a better understanding.

To do that, we're going to implement a fake database index in Ruby. It will be *woefully* incomplete, but still should be enough to give an idea of what's happening.

## Warning

What you'll see here is not, *actually*, how database indices work. It's an extremely crude approximation. I try to call out the where and how that approximation isn't valid. If you encounter anything in an actual database that doesn't match up with what you see here, I encourage you to take that as an opportunity to dive in and learn deeper.

# Making things *very* simple

We're going to build our fake index out the humble Ruby `Hash`. Those are pretty familiar, right? Store data by key and value, then you can later retrieve the value by providing the key. If you don't have a key, you're basically just working with a more expensive variant of an `Array`. Ironically, under the hood a Ruby `Hash` uses a lot of the same concepts and data structures as database indices. Anyways, this will be our substitute for writing actual data structure code.

We'll only support *unique* indices. It's possible, but messy, for us to support non-unique ones. I just don't think it's going to teach much you won't already learn here. We *will* support composite indices, and will get into covering queries that only use some of the index columns.

Probably the biggest query-time thing separating our index from a real one will be lack of support for range queries. So no `WHERE X > 0` style queries for our index. We're ignoring this because hashes don't make it easy to do efficiently, and I don't think implementing it will tell you much that direct value lookups don't. Real database indices *absolutely* are able to handle these for many different data types.

## The Index class

We'll start with a class, that we name `Index`, which will be the core of our code here. We will "implement" different SQL queries as Ruby code written in terms of this `Index` class.

We use `Index.declare` to create an (empty) index on a list of columns. Then we can add data to it by looping through the data and calling `Index#add`.

```ruby
# Allow us to efficiently answer questions about a large amount of data based on
# specific column(s) in it.
class Index
  # The column this index is handling.
  attr_reader :column

  # The columns that come *after* this one in the index.
  #
  # If this list is empty, we're at the "end" of the index column list and
  # should store row ids as our Hash values.
  #
  # If it is *not* empty, we make an `Index` class that deals with those
  # columns and use it as our Hash value.
  attr_reader :subsequent_columns

  # The Hash that represents actual index content. I'm avoiding calling this
  # `data` because it's *not* the actual data we're indexing. Confusing
  # terminology.
  attr_reader :content

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
  # that contains at least `:id` and whatever value we hvae for `column`.
  def add(data)
    value = data[column]
    if leaf?
      @content[value] = data[:id]
    else
      # If we are *not* the final column, create a new Index to represent the
      # slice of data that all shares the same value for our `column`. This
      # index should use the *next* subsequent column, and needs to know about
      # the *rest* of the subsequent columns in case it too is not the final
      # one.
      @content[value] ||= Index.new(subsequent_columns[0], subsequent_columns.drop(1))
      @content[value].add(data)
    end
  end
end
```
# What we can learn about database indices

Surprisingly, just here we can draw an important and useful inference about working with indices. The "natural flow" of accessing this data is going to be along the path dictated by the columns. Our index also can't answer questions involving columns that weren't indexed.

It's easy to imagine navigating this in column order, but *other* orders seem like a bigger challenge. Databases are full of clever optimizations that can *sometimes* make out-of-order usage possible, but generally speaking you want things to happen in-order.

# Sample data

To play with this, we'll work on sample data taken from the [US Census Bureau City and Town Population Totals](https://www.census.gov/data/tables/time-series/demo/popest/2020s-total-cities-and-towns.html#v2022) This is a list of ~20k cities in the US with their estimated population.

For the purposes of this post, I have [Cleaned it up](/static/city_populations_2022.csv) in a CSV, with state names extracted.

We're going to assume here that the combination of the `city` and `state` columns makes a record unique. That isn't *strictly* true for this data, but again it makes it easier to work with.

# Harnass code

The following code is enough to get us started in an IRB session. It assumes the above code snippet is available locally as `./index.rb`, and the csv can be found at `./city_populations_2022.csv`. 

```ruby
require "csv"

load "index.rb"

# Load the CSV, converting integer values as we go
csv = CSV.read("./city_populations_2022.csv", headers: true, converters: [:integer, :all, :all, :all, :integer])

# Store our CSV in an Array where the values are hashes of the row
# data. This will simulate the actual database table.
data = csv.map(&:to_h); nil

# Declare an index on state and city, in that order
index = Index.declare("state", "city")

data.each do |row|
  index.add(row)
end; nil
```

If we were to discard the index class and *just* look at things as nested hashes, our index would look like this:

```ruby
{
  "California" => {
    "Los Angeles" => 1444 # 1444 is the row id for this city
  }
}
```

## Finding a row by state and city

We'll start out simple: given a city and state, look up the row. We'll try it out with Los Angeles, California. In SQL, this would be: `SELECT * FROM populations WHERE state = 'California' AND city = 'Los Angeles'` 

```ruby
state = index.content["California"]
city = state.content["Los Angeles"]

# Our `id` values don't exactly correspond to Array offsets, so we have to do this.
data[city - 1]
```

# What we can learn about database indices


#### Index ordering

Notice how we're starting the lookup with the `state`? That's because it's the "beginning" of the index.

Imagine if we tried to start with the `city` first. What would that code look like? It would have to dig through *every value* in the `state` index to get at cities, then work its way backwards.

Often, your database effectively can't do this. There's too much data involved, and simply keeping track of everything you've looked at could cause problems. Plus "examine the entire index" isn't going to be a fast operation. It might pursue this strategy if you give it no better option, but you *really* want to give it better options.

#### Row lookup

Notice how, to return the data, we had to go to our "table" that is stored in `data`? That's called a "row lookup". Real databases almost certainly store the index data and row data separately, so row lookups have additional overhead that we want to be careful with.

Often, optimizing SQL queries is a process of trying to avoid any more row lookups than strictly necessary.

## Finding the total population of a state

Ok, now let's try another likely task: finding the total population of a state. We'll go with Idaho this time. In SQL this would look like `SELECT sum(population) FROM populations WHERE state = 'Idaho'`.

At first glance it might not look like our index is helpful here, but it still is. Here's code to get this *without* the index:

```ruby
sum = 0

# Let's keep track of how many times we had to go fetch a row. This is
# important, because row lookups are expensive.
rows_examined = 0

# Notice: we are visiting *every* row in the data. If we had millions or
# billions of rows, this would be really bad.
data.each do |row|
  rows_examined += 1
  next unless row["state"] == "Idaho"
  
  sum += row["population"]
end; nil

[sum, rows_examined] # => [1302154, 19692]
```

So we got our sum, it *probably* was fast on your computer (reminder: this is a tiny amount of data), but we had to look at every single row in the data. Usually, "we have to look at every row in the entire table" is one of the absolute *worst* things you can see your database doing.

So how can we use our index? We don't have a ready list of "the names of every city in Idaho", so we can't just plug that in as keys once we get to the `Idaho` index. But, we *do* have the ability to traverse a `Hash` by *values*. So we can still use our index to help us get to the state of Idaho, then crawl through its contents to find the total population.

```ruby
sum = 0

# Again, we're tracking rows
rows_examined = 0

state = index.content['Idaho']
state.content.values.each do |row_id|
  city = data[row_id - 1]
  rows_examined += 1
  sum += city["population"]
end; nil

[sum, rows_examined] # => [1302154, 199]
```
So now we have the *same* sum, but we looked at roughly 10% of the rows. That's a *huge* win.

# What we can learn about database indices

Databases don't just use indices for cases where they have every single relevant key. It's a data structure that they can dig through, and that can help significantly.

Sometimes they do this by "skipping over" intermediate keys to get to the final rows, like what we did here. It's worth noticing that this was only possible because our index was defined as `(state, city)`. If it had been `(city, state)`, we would have had to examine every single city name to see if it was in the state. That's usually still *better* than crawling every row of the data, but it's nowhere near as good as what we just experienced.

When you're defining a composite index, it's *really* important to think about the cases where you might end up querying only some of those columns. Getting the column order right will maximize the value you get out of the database's work in maintaining the index.

## A new index for even faster population totals

Let's say this kind of population query is extremely important, and we've found the above "only accessing 10% of the rows" to *still* be too slow for our needs. What can an index do for us?

We've done more or less everything we can with our existing index. If our system supported non-unique indices, we could make an index on just `state` that would allow us to directly jump into rows, but it wouldn't change the amount of rows we're looking at.

Let's build *another* index, one that extends our previous index with population values. So it would look like `(state, city, population)`. Here's how:

```ruby
population_index = Index.declare("state", "city", "population")

data.each do |row|
  population_index.add(row)
end; nil
```

Because `state+city` was already unique, `state+city+population` is also going to be.

Here's a sketch of it as a Hash:

```ruby
{
  "California" => {
    "Los Angeles" => {
      # NOTE: This "population" Hash will always be a single key (the
      # population) pointing to the row id.
      3898767 => 1444
    }
  }
}
```

This index can give us our population total *without touching a single row*!

```ruby
sum = 0

state = population_index.content["Idaho"]

state.content.values.each do |city|
  sum += city.content.keys.sum
end; nil

sum # => 1302154
```

Notice how `data` is not even mentioned in this code. We're answering queries *just* from the index content!

# What we can learn about database indices

Since our index reflects the underlying data, we can use the index contents *in place of* the actual data. Databases use this trick *a lot*, and it's an incredibly effective optimization.

It's generally safe to assume that your data on disk isn't organized in a way that makes any particular lookup effective. Before when we read 199 rows to get our data, it's safe to assume that none of those rows lived next to each other in a way that allowed the operating system to avoid doing 199 disk reads.

By comparison, even when the index is serialized to disk, all of the relevant bits of information live closer together. It's very likely that reading the disk block that gave us one relevant `city` *also* happened to load and cache other cities we needed. Plus our index data is a lot smaller/denser than the actual row data. So even digging everything up off the disk involved fewer disk reads.

When trying to look up actual city records, the same "skip over a column" trick that we did in the last section can work here. So it's possible to go from `(state, city, population)` to the city record even with just `state` and `city`. This index could handily serve every query we've seen so far.

## Finding the total population of EVERY state

Now we're going to try to handle this query: `SELECT state, sum(population) FROM populations GROUP BY state`.

STOP! Before you read further, I want you to think about how you'd solve this. You have three options now:

* Walk through all the data rows
* Try to use the original index
* Try to use the population index

That act of "deciding how to get at the data" is called *Query Planning*. It's an important part of how databases work. Get deep enough into database performance and you're going to have to become intimately familiar with your database's query plan explanations. Examining that output is a key way to help debug slow queries and figure out what changes need to happen to make them not-slow queries.

In this case we have only three options, and it's (probably) relatively easy to pick which one will be "the best". But, let's think them through in a rough approximation of how a query planner might look at this.

If we assign a "cost" to data and index reads, we can weigh our options by "total cost":

* Walk all the rows: 20,000 data reads + 0 index reads
* Use the original index: 20,000 data reads + 20,000 index reads
* Use the population index: 0 data reads + 20,000 index reads (reminder: all needed data is in the index)

It's generally accurate to assume that index reads are cheaper than data reads. So we'd want to "weigh" data reads higher. The actual process inside a real database is much more complicated, but here we'll just assume data reads are 5x as expensive.

That gives us total costs of: 100,000 120,000 and 20,000 respectively. Which means we should go with the last option.

*Sidenote: to make it accessible, this cost calculation is wildly naive. Real databases track a lot more information than "how many rows are there", and have more detailed insights about both the characteristics of the data and the specifics of how it is stored. Imagine you spent years refining this concept to fix every case where your cost predictions were wrong, and you're closer to how databases actually work.*


So, how do we find per-state populations? That one again comes out kind of straightforward:

```ruby
result = {}

population_index.content.each do |state, cities|
  result[state] = 0

  cities.content.values.each do |population|
    result[state] += population.content.keys[0]
  end
end; nil

result
```

# What we can learn about database indices

Again, we're using the index as a *source* of information rather than just a way to *get to* information. It's worth reiterating this because it comes up so often in real world scenarios.

We also, in our simulated query planning, saw a case where using an index was *slower* than reading the entire table. In practice, these scenarios are rare, but they can happen. Sometimes you'll look at a query plan and wonder why the database is ignoring an index, only to find that you're missing details where the index makes things *slower*. In this case that detail was "we're asking to read the entire table", but it's definitely not the only one.

We're also, in our `result` hash, just getting a glimpse into result buffering. Again it's worth imagining what we would do in a scenario where there was so much data that just storing this `result` in memory wouldn't work. 

## Wrapping up

Hopefully this helps a little to demistify database indices. As I mentioned at the start, the *actual* data structures vary significantly from what we're using here, but I've tried to keep the reasoning and thought processes consistent.

Despite the inaccuracies, you can get pretty far using this "wandering through nested hashes" view of how database indices work. Perhaps the best extension to your mental model would be imagining a hash that also includes the ability to do inequality comparisons on keys. Like if a `Hash#lookup` method existed that took a Ruby `Range` as an argument and could efficiently give you the values where keys were inside of that range.

If all of this has you interested in what the internals of an index *actually* look like, you can start by studying [B-trees](https://en.wikipedia.org/wiki/B-tree#:~:text=In%20computer%20science%2C%20a%20B,with%20more%20than%20two%20children.). They're probably the most commonly used data structure for this purpose. Many databases support alternative index types based around different data structures, which is where you really start getting deep into the benefits and drawbacks of each one.

If you'd like to know more about query plans and how databases handle the topic of picking an algorithm to look up the data, that unfortunately gets pretty specific to the database involved. If you're using [MySQL](https://dev.mysql.com/doc/refman/8.0/en/execution-plan-information.html) or [PostgreSQL](https://www.postgresql.org/docs/current/using-explain.html) I've linked to the relevant sections of their documentation. Because databases are attempting to generate the best possible plan out of (potentially) a huge number of choices in a tiny fraction of time, query planning gets kind of hairy and detailed fast.

If this has peaked your interest in how to effectively use indices, [Use the index, Luke](https://use-the-index-luke.com/) is a fantastic resource. It even includes an introduction to B-trees and resources tailored to multiple database types.
