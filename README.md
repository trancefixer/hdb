FAQ
===

Usage
-----

```
Usage: hdb [-e] [-d] [-v] [-s] [-p] [-c cmd] [-l label] [-f fstype] [-g groupdir] [-m mpoint] /dev/sdX /path/to/backup
    -e, --encrypt                    Encrypt the hard drive medium using LUKS cryptsetup
        --lookup                     Look up metadata (is very slow)
    -d, --debug                      Turn on debugging information
    -v, --verbose                    Output more information
    -s, --skipeject                  Skip ejecting the medium on successful completion
    -p, --profile                    Profile the code
    -c, --command CMD                Command to perform (CMD=create, ...)
    -l, --label LABEL                Label for human consumption
    -f, --fstype TYPE                Type of file system
    -g, --groupdir DIR               Group metadata directory
    -m, --mpoint DIR                 Mount point for medium
    -h, --help                       Display this screen
```

Example:

```
hdb -m /Volumes -l label_001 /dev/disk1 $HOME
```



Terminology
-----------

*Metadata* is the information about a file - its filename within the archive, the modification time, the SHA-512 hash

*FileList* is a collection of Metadata

*FileSet* is a FileList plus the host, parent directory, and other information specific to the backup, but shared among all the files in the backup

*FileSetGroup* is the collection of saved FileSets, saved in a place known as the groupdir

*groupdir* is where bookkeeping data are stored, defaults to \$HOME/.hdb, or wherever is specified by HDB_GROUPDIR or -g option

*label* is the filename of a FileSet within the groupdir; it is suggested you label your storage media this way. By default it will be an unused integer starting at one.

Features
--------

-   Works with any medium that shows up as a disk device in Linux

-   Keeps track of what files were stored on what disks

-   Keeps track of what you have already backed up, so that you don't need to back it up again

-   Stores SHA-512 hashes of files that it backs up in the FileSetGroup

-   Stores modification times to avoid costly SHA-512 recalculation

-   Supports LUKS-style cryptsetup for encrypted backups

-   Metadata is stored in ordinary text files, meaning you can manipulate them easily with the Unix utilities.

-   Backup media formatted as a normal file system; no special tools required to access or recover backed-up data

-   Keeps owner, group IDs same in the copy

-   Resets atimes after reading a file

Limitations
-----------

-   Filtering out files which have already been backed up (FSG filtering) is still under development

-   Only copies files, directories, and symlinks; no special files (devices, pipes, Unix domain sockets, etc.)

-   Does not preserve hard links (they get unlinked during copy)

-   Does not preserve *some* inode access times (directories, symlinks)

-   Does not attempt to pack the maximum amount of data on each medium; simply tries each file in order, skipping ones that don't fit

-   Does not have the ability to store leading directories when backing up a subdirectory; that is, if you back up /home/user, which has three files in it, those three files will appear in the root directory of the backup medium.

-   Does not keep permissions. This is harder than it seems due to umask.

-   Assumes that it should format all media; does not have the ability to update backups already stored on labelled disks

-   Does not deal with newlines in filenames properly

-   Does not preserve ACLs

-   Only targetting Linux right now, but could be ported *relatively* easily (some of the fancier features are more difficult)

-   For a full list, see the code and grep for TODO

Status
------

-   Still under development - **alpha testers only**

-   The aforementioned [limitations](#Limitations) make it suitable for data files only, not system backups.

-   Tested on datasets of 700,000 files and 700GB.

-   Backups of 700GB of large files can take 16 hours; backups of 700,000 small files can take nearly a week.

-   *Resident* memory size can reach over 1GB on large data sets (e.g. over 1,000,000 files in backed-up media).

Background
==========

Being a security expert and system administrator, I recognize that backups should play a very important role in security and general disaster preparedness.

After building two file servers with multi-terabyte capacity, I found myself looking for an economical way to create backups that I could put on a shelf and use later in case of disaster. However, I found myself dissatisfied with the way I had been doing backups in the past. Allow me to go back in time a bit and describe the techniques I used to illustrate why they are deficient for modern systems.

Backing Up To Tape
------------------

Unix system administrators have long backed up to tape. Although the media have changed from half-inch reels to modern media like DLTs, from a system administration standpoint, the technology has not changed much.

In the olden days, hard drives were small and tapes relatively large, so a system administrator could use a tool like "tar" (*t*ape *ar*chive) to serialize and back up file systems to tape. There were several bookkeeping issues here:

-   Remember when the tape was created

-   Remember which file systems had been dumped

-   When backing multiple filesystems on the same tape, keep track of their order

-   When a file system spanned two tapes, keep track of that information

Later, in BSD Unix, tools such as "dump" and "restore" came along, which kept track of the last time that a filesystem had been dumped and let the sysadmin know when it was due for another.

When all the file systems could fit on a single tape, performing backups was easy. However, once you got into multiple tapes, a sysadmin had to "babysit" the backup, changing tapes as needed. This was an annoying task, and not the best way to spend a system administrator's time. In large shops, this task was sometimes given to "operators", who were not full system administrators.

Later, automated tape changers came onto the market to solve this need, but they tended to be expensive. They also spurred special software to be created to do things like change which tape is in the drive. I personally bought a SCSI 8-tape DAT drive, which was capable of switching tapes. This suited my needs for a fairly long period of time.

Tape drives also had to be cleaned with special media, and this was an additional headache. In some cases, bad batches of tapes could force system administrators to clean the drive multiple times.

Hard drive speeds and capacities have improved, while tape technology remains relatively *slow* and *small*, with the exception of some very expensive "business grade" devices that require fast but expensive connections to the computer.

Also, since tape is a linear device, actually recovering data from the tape can involve a great deal of time seeking through the tape to the appropriate file.

Also, if one wants to keep tapes a long time, one may have to make sure that they are kept in climate-controlled conditions. It seems reasonable to assume that the plastic tape itself may become brittle, or that high heat could change the coercivity of the tape enough to corrupt data. I personally kept my tapes in a metal military ammunition box with an airtight seal.

A hidden danger here is that not all Unixes write to tape in the same way. I haven't had the opportunity to investigate the details, but all the tapes I made on BSD Unix systems were unreadable on Linux systems, even when using the same hardware (SCSI controller, tape drive)!

Encrypting tapes was not too difficult in some situations; you could simply pipe tar through a filter that encrypts the data, and then pipe that to "dd" to send the data to the tape in correctly and consistenly-sized chunks.

Backing Up To Discs (CDs or DVDs)
---------------------------------

When affordable CD writers came on the market, it seemed like a good replacement for tape. After all, CDs were random-access media, which meant that recovering files from a CD could be easy.

But CDs came with their own host of problems. CDs were invented for digital music, and have a single data track that spirals around the disc, much like a phonograph record. Thus, at a low level, they were not as random-access as one would like. It is my understanding that one can seek to a given region of the disc, and then zero in on the data you would like. DVDs are the same way.

Writing to discs is different enough from writing to other things that it requires special tools to create the discs (this process is called "burning"). These programs do the job well enough, leaving it to the user to select files for copying.

CDs and DVDs also have their own file system formats, which is different enough from Unix that it sometimes makes life difficult. For example, some formats do not support long file names, and some formats impose a maximum limit on pathnames that is smaller than the limit on Unix systems.

Next, burning discs is *very slow* compared to hard drive speeds.

Most disc drives accept only one disc, so the system administrator still needs to be around to change discs if the backup requires several of them. Their capacities are still small enough compared to hard drives that it takes several to back up a moderately priced hard drive.

Also, very few burning programs allow you to span a file over two discs; that is, if you have a file which is larger than the disc, you may not be able to back it up at all.

I have tried backing up my movie collection to DVDs, and one time I thought I had lost my data. When I attempted to recover my files, which had never been read, I found that one DVD had scratches on it that prevented it from being read. This is interesting since as far as I know, it had only been in the drive and in the 3-ring binder I used to store all my discs.

CDs did not inherently address any of the bookkeeping requirements mentioned for tapes, although doubtless some software packages can do this.

It is also not clear how to encrypt filesystems on CDs or DVDs. I seem to recall it being possible to create an ISO image on the hard drive that is encrypted, and then burn it to the disc, but I have not seen any backup programs which do this natively.

Disk-to-Disk Backups
--------------------

Hard drive capacities have skyrocketed lately, and thanks to SATA drives being hot-pluggable, and USB/eSATA docking bays (available for less than \$50 from Fry's) it is now possible to use hard disks themselves as removable backup media.

Disk-to-Disk backups have the following advantages over older backup strategies; they use a fast bus (USB 2.0 or better yet, eSATA), they have high capacity, they are random-access, they don't require any special programs to write data to them, and they don't require expensive hardware to read them. Also, a hard disk has a very long shelf life and is much less prone to damage than a disc.

HDB
===

Assumed Problem Domain
----------------------

HDB is not for everyone. Due to its current [limitations](#Limitations), it is not yet suitable as an all-purpose backup utility.

### Backup System

The scenario that interested me is that I wanted to keep online copies of my movies on DVD so that mythtv (mythbuntu) could play them. However, ripping from DVDs is non-trivial, so I wanted to back up my full collection in case I lost my file server's data (for whatever reason, including a stray rm).

In other words, the storage medium was a subset of the files on my hard disk.

It may be desirable to *update* the storage medium, so as to save time copying data that is already there.

### Archive Data

In this case, you have a large collection of things you want to store permanently, but don't want to keep on your main storage - you merely with to archive it for possible later use.

In this case, you may want to *update* the storage media with files, instead of just formatting it and copying files onto it; you do not want to format the disk if it contains previously-archived data!

Also, you want to remove the files after copying them, or (better yet) after successfully copying everything and updating metadata.

### Regenerate Metadata

In this case, you formerly either backed up or archived, and then mounted it and modified it for some reason, possibly adding or deleting or modifying the contents of files.

In this case, you do not want to format the disk, and you merely want to regenerate metadata for the files.

### Detect Changes

In this case, you formerly backed up, and then want to detect changes to those files on the file system.


Ideas
-----

-   Generating SHA-512 hashes is time-consuming; almost as time consuming as backing up the files themselves

    -   Have a command-line option to tell it to not trust modification times, like rsync

    -   Have a command-line option to check hashes N of M times (randomly)

-   Improve accuracy of SHA-512 guessing by storing and testing file size as part of metadata

-   When making copies, keep user and group

-   Use hard links to save space

    -   for modeling files hard linked together on the source disk

    -   for de-duplicating (essentially making them the same object on the backup)

    -   for storing multiple backups in small amount of space (like rsnapshot)

-   Packing drives optimally is NP-hard (<http://en.wikipedia.org/wiki/Knapsack_problem>), but it is well-studied and there are good approximations

-   Implement a change-detection mechanism like tripwire (<http://www.tripwire.org/>)

-   More metadata in filesets would suggest a more complex file format; XML may be a reasonable solution, allows for us to add data without breaking things

-   Allow multiple levels of verbosity, and put in progress indicators at higher levels

-   Copy symlink referents if they're outside the tree, like rsync --copy-unsafe-symlinks

-   Option to exclude certain directories from the backup

-   Config file describing files to back up and/or integrity-check

-   Could represent filesystem metadata (like SELinux labels) by

    -   representing files as directories (with the contents being a file within that directory)

    -   storing metadata as special entries within each directory

-   Allow for more variety in FileSet labels instead of natural numbers (e.g. names, name plus number, etc.)

-   Use hdparm to put drive into standby when done

-   Allow user-defined scripts to run at certain points in procedure

-   Allow for multiple identical copies of the backup medium

-   Have a flag to control whether we reset atimes or not

How HDB Works (out of date)
---------------------------

For an up-to-date version, please read the code. Don't worry, it's straightforward, with lots of comments.

First it creates a groupdir if you don't already have one. The groupdir is where it stores bookkeeping data; collectively they are represented as a **FileSetGroup** object.

You give HDB a directory name to back up, and it first goes through that directory recursively, collecting a list of all files, directories, and symlinks it might have to copy. It generates a Metadata object for each one. The collection is called the FileList, and when you tack on the host and directory, and other information that is not specific to any individual file, it is called a FileSet.

Each drive has a label, which is user-defined, but defaults to an unused integer starting at one. The FileSet for that label is stored in the groupdir, using the label as a filename.

Next, HDB scans the groupdir, looking for filesets that have the same hostname and directory. If it finds one, it removes all the files in that set from the current set; that way, you don't back anything up twice.

Next, HDB makes a filesystem on the drive, mounts it, and starts copying data.

If there is not room for a file (or directory or symlink), that file is removed from the set.

Finally, if it completes properly, it writes out the fileset to the groupdir, using the label as the filename.

For More Information
====================

-   *HDB code* (<http://www.subspacefield.org/security/hdb/code/>)

-   *HDB mailing list* (<http://lists.bitrot.info/mailman/listinfo/hdb>)

-   *HDB history - for how the project evolved* (<http://www.subspacefield.org/~travis/hdb_history.html>)

Related Links
=============

General Backup Information
--------------------------

-   *Backup Central* (<http://www.backupcentral.com/>)

-   *Choosing a new backup solution - Duplicity, rdiff-backup or Rsnapshot* (<http://www.bitflop.com/document/75>)

-   *Backup on Linux: rsnapshot vs. rdiff-backup* (<http://www.saltycrane.com/blog/2008/02/backup-on-linux-rsnapshot-vs-rdiff/>)

-   *ServerFault: Which is best for backups - rsync vs rdiff vs rsnapshot* (<http://serverfault.com/questions/136861/which-is-best-for-backups-rsync-vs-rdiff-vs-rsnapshot>)

-   *Encrypted OS-independent backups with rsnapshot, TrueCrypt and NTFS* (<http://blog.0wnz.at/index.php?/archives/6-Encrypted-OS-independent-backups-with-rsnapshot,-TrueCrypt-and-NTFS.html>)

-   *The Source of All Tape Knowledge* (<http://www.subspacefield.org/~vax/unix_tape.html>)

Backup Tools
------------

-   rsync (<http://samba.anu.edu.au/rsync/>)

-   rsnapshot (<http://rsnapshot.org/>)

-   rdiff-backup (<http://rdiff-backup.nongnu.org/>)

-   rbackup (<http://rbackup.lescigales.org/>)

-   duplicity (<http://www.nongnu.org/duplicity/>)

-   boxbackup (<http://www.boxbackup.org/>)

-   *Easy* Automated Snapshot-Style Backups with Linux and Rsync (<http://www.mikerubel.org/computers/rsync_snapshots/>) - has a great list of references to other tools
