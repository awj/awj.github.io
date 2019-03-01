---
layout: post
title:  "Understanding MySQL Multiversion Concurrency Control"
date:   2018-09-16 11:02:55 -0700
categories: [database, mysql]
excerpt: >-
    In which we figure out how MySQL writes new data without showing it in old queries.
---

MySQL, under the InnoDB storage engine, allows writes and reads of the same row to not interfere with each other. This is one of those features that we use so often it kind of gets taken for granted, but if you think about how you would build such a thing it’s a lot more detailed than it seems. Here, I am going to talk through how that is implemented, as well as some ramifications of the design.

# Allowing Concurrent Change
Unsurprisingly, given the title of this post, MySQL’s mechanism for allowing you to simultaneously read and write from the same row is called “Multiversion Concurrency Control”. They (of course) [have documentation](https://dev.mysql.com/doc/refman/8.0/en/innodb-multi-versioning.html) on it, but that dives into internal technical details pretty fast.

Instead, let’s talk about it at a little higher level. This concept has been around for a long time (the best I can do hunting down an origin is a [thesis](https://dspace.mit.edu/handle/1721.1/16279) from 1979). The overall answer for allowing concurrent reads and writes is pretty simple: writes create new versions of rows, reads see the version that was current when they started.

# Version tracking
Obviously if we’re going to keep track of versions, we need something to differentiate them. This tool needs to distinguish one version from another, but ideally it would also make it easy to decide which version a read operation should see.

In MySQL, this “version enabling thing” is a transaction id. Every transaction gets one. Even your one-shot update queries in the console get one. These ids are incremented in a way that allows MySQL to determine that one transaction started before another. Every table under InnoDB essentially has a “hidden column” that stores the transaction id of the last write operation to change the row. So, in addition to the columns you may have updated, a write operation *also* marks the row with its transaction id. This allows read operations to know if they can use the row data, or if it has been changed and they need to consult an older version.

# Reading older version
For the cases where your read operation hits on rows that have been changed, you’ll need an older version of the data. The transaction id comes into play here too, but there’s more info needed. Every time MySQL writes data into a row, it *also* writes an entry into the rollback segment. This is a data structure that stores “undo logs” used to restore the row to its previous state. It’s called the “rollback segment” because it is the tool used to handle rolling back transactions.

The rollback segment stores undo logs for each row in the database. Every row has *another* hidden column that stores the location of the latest undo log entry, which would restore the row to its state prior to the last write. When these entries are created, they are marked with the *outgoing* transaction id. By walking the undo log for a row and finding the latest transaction *before* a read transaction the database can identify the correct data to present to a transaction.

# Handling deletes
Deletion is handled by a marker in the row to indicate a record was deleted. Delete operations *also* set the row’s transaction id to their transaction id, so the process above can present a pre-delete version of the row to read operations that started before the delete.

## When are versions deleted
MySQL obviously cannot keep a record of every change that happens in the database for all time. It doesn’t need to, though. Undo logs can be removed as soon as the last transaction that could possibly want them completes.

Similarly, rows that have been marked as deleted can be outright abandoned once the oldest active transaction started after the deletion. These rows and undo logs are physically removed to reclaim their disk space by a “purge” operation that happens in its own thread in the background.

# What about indexes
So, to recap, MySQL handles versions by keeping the row constantly up to date and storing diffs for as long as currently running queries need them. That’s only half the story though, indexes need to support consistent reads as well. Primary key indexes work much like the above description for actual database rows. Secondary indexes are a little different.

MySQL handles this in two ways: pages of index entries are marked by the last transaction id to write in them, and individual index entries have delete markers. When an update changes an indexed column, three things happen: the current index entry is delete marked, a new entry for the updated value is written, and that new entry’s index page is marked with the transaction id.

Read operations that find non-delete-marked entries in pages that predate their transaction id use that index data directly. If the operation finds either a delete marker or a newer transaction id, it looks up the row and traverses the undo log to find the appropriate value to use.

Similar to the purging of deleted rows from expired transactions, delete-marked index entries are also eventually reclaimed. Because there is always a fresh new entry to work with *somewhere* in the index, MySQL can be a little more aggressive at cleaning those up.

# What do I do with this information?
So, given the above, what can we take home to make our lives better? A few things. Keep in mind with all of this that database performance can be very difficult to analyze. Each point below is just one potential piece of the story of what could be happening with your data.

* Big transactions are painful: Long running transactions don’t just tie up a connection, they force the database to preserve history for longer. If that transaction is reading through a large swath of the database subsequent writes will force it to read the rollback log, which may be in a different page of memory or even on disk.
* Multi-statement transactions need to commit quickly: This is another variety of “big transactions are painful”, but it’s worth calling out. MySQL does not “kill” active transactions. If you open a transaction, query out data, then spend two hours in application code before committing, MySQL will faithfully preserve undo history for two hours. Every moment of an open transaction forces more undo history. Commit as quickly as you can and do your processing outside of transactions whenever possible.
* Writes make index scans less useful. The whole point of an index is to answer questions about your data without actually looking at your data. Delete markers on index entries, and transaction stamps on index pages, force the database to read your data. Think carefully about using composite indexes with columns you aren’t querying. Your queries will pay the price for updates to those columns anyways.
* Rapid fire writes magnify the penalties for reads. If you have a lot of data to write, especially to the *same row*, write it in chunks instead of one-by-one. Each write generates a transaction id, relevant undo logs, and makes a mess of secondary indexes. Chunking writes together increases the chances that reads will find valid index data, and lowers the size of undo logs they have to wade through. There’s an opposite extreme where one big write might have too much data, so it’s important to look for the happy middle ground here.
* “Hot” rows are hot for all columns, not just updated ones. A row that stores a frequently updated counter forces more row transaction id updates and undo log entries. Queries that start before the counter is incremented, even if they don’t use the counter, still have to traverse undo logs for the row state when they started. That same logic applies to extremely frequently updated timestamps that aggregate change times across the relations to a row. If possible, batch those updates beforehand or consider storing them in a separate table you can join to when needed.
* Consider separating reporting from direct/application use reads. Reporting queries tend to scan large sections of the database. They take a long time and thus force the preservation and consumption of more undo history. Most application behavior is more direct: it knows specific records to retrieve and goes straight for them. If you’re already using read replicas, consider dedicating one to reporting so that your application queries don’t pay the undo storage penalties of reporting.

# Final thoughts
It’s worth noting that this is not the only way to implement MVCC. PostgreSQL handles this task by storing the minimum and maximum transaction ids where a row should be visible. Under that scheme, updating a row sets the maximum transaction id on it and creates an entirely new row entry by copying the original and performing the update in that copy. This avoids the need for undo logs, but at the cost of copying all row data for each update.

The point here is that, for cases where you are really trying to push database performance, understanding a few of the bigger details of the internals can pay off. Many of the takeaways I listed are only going to be applicable in extreme use cases, but in those cases knowing how the database goes about versioning data can make understanding performance problems easier.
