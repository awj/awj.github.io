---
layout: post
title:  "Should we be caching"
date:   2019-02-05 19:12:31 -0700
categories: [caching, rails, performance]
excerpt: >-
    Or: how to talk yourself out of one of the hardest problems in computers
---

Caching is one of those weird things in programming, like inheritance and concurrency, where everyone parrots the line about how tough it is then *immediately* turns to it when they have a problem.

Chances are good that *somewhere* in your app, you've got a cache. Maybe it's explicitly coded, or maybe it's implicit in headers set as part of sending data over the wire.

Chances are *also* pretty good that at least some of that caching is *causing invalid results*. There's even an outside possibility it's making things *slower*. In this post I'll talk through how to think about caching to be sure it's worth the pains it can cause.

# First, applicable scope
I'm *only* talking about read-through caches here. Ones where we update the cache synchronously when reads come up empty/expired. It's one of the most common forms of caching.

The standard [Rails low-level cache](https://guides.rubyonrails.org/caching_with_rails.html#low-level-caching) (i.e. `Rails.cache.fetch`) is an example of this.

There are other caching options that might change the thought process, so if you're looking at one of those be careful using this logic.

# Good reasons for caching
Before we get into "is a cache worthwhile" questions, let's talk through the reasons you might be adding caching.

## Efficiency
This is *the big one*. You're doing a bunch of work to obtain results that don't change, so saving the results avoids repeating that work.

The goal here is to increase throughput and improve user experiences by making things faster.

Although making things faster is generally desirable, it's important to qualify (*not* quantify) this improvement. For most use cases, optimizing a 10ms request into a 1ms request isn't particularly useful. 10ms already *feels* fast, so users won't notice that it's 10x faster.

Thankfully, there's been some study in this area.

First off, we'll look to [Jakob Nielsen](https://www.nngroup.com/articles/response-times-3-important-limits/) for some important tiers of user perception on waiting for a task:

* < 0.1s - feels instantaneous
* < 1.0s - keep your flow of thought
* < 10.0s - keep your focus

A cache that moves your user from one "tier" into another is helping immensely, even if the overall improvement doesn't seem impressive.

Second, we'll look at [Neil Patel](https://neilpatel.com/blog/loading-time/) (as referred to us by [Google Analytics help](https://support.google.com/analytics/answer/4589209?hl=en)) to figure out that we see a 7% bounce rate increase for every 1s of load time.

Combining these, we can regard 1s increments as valuable changes, >10s request times as extremely problematic, and getting under 1s and especially 0.1s as huge improvements. Moving about inside those 1s increments, and especially underneath that 0.1s threshold, is less valuable than crossing a boundary.

## Insulating a data store
This is also a common reason for caching. Here your goal isn't speed, but availability. You're trying to protect your data store from workloads it can't handle by avoiding some of the work.

This requires different thought and planning, because scenarios where your cache isn't available become a *system* problem instead of a user experience problem. For example, if your frontend servers lose their in-memory caches during a deploy, the data store will be on its own until the caches refill. If it can't handle that load spike, you go down.

It's not uncommon to *initially* deploy a cache for efficiency reasons, only to have request growth turn it into an "insulate the data store" cache.

For this caching goal, hit rate is more important than raw performance. The overhead of reaching across a network to a dedicated caching server is usually acceptable compared to your app servers needing to refill in-memory caches.

# Bad reasons for caching
There are a few common cases where people *think* the solution to a problem is caching, when in reality it's somewhere between a Band-Aid and harmful.

## Very slow queries
You cannot use read-through caching to "get around" queries that take longer than your app server's timeout. If your query times are approaching your timeouts, at best a cache is going to make the error intermittent. That's better than nothing, but not good.

In these cases, you need to focus on speeding up the queries. Often queries are either over-fetching data or filtering against columns that aren't properly indexed.

## Slow view fragments
Similar to the above about queries, sometimes people turn to caching to solve problems with request timeouts during view rendering. Again, this isn't going to actually solve the problem, just (maybe) push it off for a bit.

Usually, those slow view renderings are database queries in disguise. Look for N+1 query behavior. Are you loading too much data in a page?

## It "might" turn out to be slow
Often people slap caching on things they *think* will be slow. Equally often, this is the wrong assumption. Unless you've done some analysis to back up the idea, this is another form of premature optimization. You're ponying up for the costs of caching without being sure they're worth paying.

# The costs of caching
Let's start with the simplest decision: can you afford the server cost? Either you're caching on some shared resource like Redis, or you're doing filesystem/memory caching. In either case you're increasing resource usage somewhere.

The most important "cost" of caching lies with developers and users, not servers. Caches are *very* hard to reason about, which makes them easy to get wrong, which can cause all kinds of havoc.

In a system without caching, every result simply is what the source of truth says. A user changes a record, that gets committed to the database, the very next page shows the new data. Easy peasy.

When caching is involved, stale caches mean what your database tells you isn't always what users see. This can undermine trust, and in worst cases cause incorrect behavior.

Beyond user-facing consequences, caching means *more* code. It's more work to update, and every relevant data change also needs to worry about caching concerns. Invalidating *just the relevant* cache keys is a hard problem. Get it wrong and your hit rates plummet, or you serve stale data, or maybe both at once.

Ultimately, we have to weigh the benefits against these costs. Unfortunately, it's a difficult comparison. The benefits are easily quantifiable and the costs are highly subjective.

# The caching equation
When trying to answer "is a cache making things faster", there's a relatively simple formula to use. Keep in mind that our cache system is its own data store, with its own access time.

```ruby
hit_rate # % of cache lookups with validly cached data
miss_rate # 100 - hit_rate
lookup_time # time (ms) to consult the cache (hit or miss)
query_time # time(ms) to run the query
fractional_hit_cost = hit_rate * lookup_time
fractional_miss_cost = miss_rate * (lookup_time + query_time)
cached_query_time = fractional_hit_cost + fractional_miss_cost
```

The difference between `cached_query_time` and `query_time` is how much caching is helping (or possibly hurting) you.

The beauty of this is that you can plug it into a spreadsheet and play with the numbers. Fill in what you think the hit rate would be, along with lookup and query times, and you're able to tweak numbers to explore the benefits before doing any coding.

# What is a "good" hit rate
This is a pretty natural question as part of caching decision making, but I think in some ways it's the wrong question.

A better question would be "is caching worth it", and the hit rate is only part of that.

If the *benefit* you're looking for is in user experience, then how often will caching move users between those 0.1/1/10 second thresholds? How much developer complexity and user uncertainty is it adding?

If the *benefit* you want is insulating your data store, how effectively is it doing that? How much load are you eliminating? Are you protected in high usage scenarios? A high hit rate cache of an inexpensive query may not be as useful to you as a lower hit rate for an expensive one.

This isn't to say that hit rates aren't important, they definitely can be, just that hard and fast numbers aren't the best way to evaluate this problem.

# When should I cache?
That's the real question, huh. Unfortunately, like most other complicated things in this discipline, the answer is "it depends".

You have to weigh the potential user and system benefits against the developer costs in getting caching right, and the business costs when you get it wrong. Those things aren't reducible to simple math problems, but it definitely helps to go into the situation with them in mind.
