#! /usr/bin/ruby

# These are the unit tests that require you to be root to run them
# TODO: Remove directory assumptions (like /mnt) and Linux-isms (ext2, losetup)

$LOAD_PATH << File.join(File.dirname(__FILE__))
require 'hdb'

require 'test/unit'

module HDB

  # TODO: check for /mnt in mount output before running
  MP='/mnt'
  LD='/dev/loop0'

  class FileSystem

    def initialize(size)
      self.makefile("fs.img", size)
      system("losetup #{LD} fs.img > /dev/null")
      system("mkfs -t ext2 #{LD} > /dev/null 2>&1")
      system("mount #{LD} #{MP} > /dev/null")
    end

    def teardown
      system("umount #{MP}")
      system("losetup -d #{LD}")
      FileUtils.rm('fs.img')
    end

    def makefile(name, size)
      File.open(name, "w") do |f|
        content = "\0" * size
        f.print(content)
      end
    end

  end

  class TestFileSystem < Test::Unit::TestCase

    def test_file_system
      fs = FileSystem.new(100 * 1024)
      assert(system("mount | grep -q #{MP}"))
      fs.teardown()
      assert(system("mount | grep -q #{MP}") == false)
    end

  end

  class TestPartialCopy < Test::Unit::TestCase

    def setup
      @fsys = FileSystem.new(100 * 1024)
      FileUtils.mkdir 'a'
    end

    def test_create_file_too_big
      @fsys.makefile('a/a', 200 * 1024)
      fs = FileSet.new()
      fs.make!('a')
      assert(fs.filenames.include? 'a')
      fs.copy(MP)
      assert(fs.filenames.include?('a') == false)
    end

    def test_create_two_files
      @fsys.makefile('a/a', 75 * 1024)
      @fsys.makefile('a/b', 75 * 1024)
      fs = FileSet.new()
      fs.make!('a')
      assert(fs.filenames.include? 'b')
      fs.copy(MP)
      # puts `ls -laR #{MP}`
      # First file gets copied
      assert(fs.filenames.include?('a'))
      # Second file does not
      assert(fs.filenames.include?('b') == false)
    end

    def teardown
      FileUtils.remove_dir('a')
      @fsys.teardown
    end

  end

end
