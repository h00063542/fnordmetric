/**
 * This file is part of the "FnordMetric" project
 *   Copyright (c) 2014 Paul Asmuth, Google Inc.
 *
 * Licensed under the MIT license (see LICENSE).
 */
#include <string>
#include <unistd.h>
#include <fcntl.h>
#include "inputstream.h"
#include "runtimeexception.h"

namespace fnordmetric {
namespace util {

std::unique_ptr<FileInputStream> FileInputStream::openFile(
    const std::string& file_path) {
  auto fp = file_path.c_str();
  int fd = open(fp, O_RDONLY);

  if (fd < 1) {
    RAISE_ERRNO(RuntimeException, "error opening file '%s'", fp);
  }

  auto csv_file = new FileInputStream(fd);
  csv_file->readNextChunk();
  return std::unique_ptr<FileInputStream>(csv_file);
}

FileInputStream::FileInputStream(int fd) : fd_(fd) {}

bool FileInputStream::readNextByte(char* target) {
  if (buf_pos_ >= buf_len_) {
    readNextChunk();
  }

  if (buf_pos_ < buf_len_) {
    *target = buf_[buf_pos_++];
    return true;
  } else {
    return false;
  }
}

FileInputStream::kByteOrderMark FileInputStream::readByteOrderMark() {
  static char kByteOrderMarkUTF8[] = "\xEF\xBB\xBF";
  if (buf_pos_ + 2 < buf_len_ &&
      strncmp(buf_ + buf_pos_, kByteOrderMarkUTF8, 3) == 0) {
    buf_pos_ += 3;
    return BOM_UTF8;
  }

  return BOM_UNKNOWN;
}

void FileInputStream::readNextChunk() {
  int bytes_read = read(fd_, buf_, sizeof(buf_));

  if (bytes_read < 0) {
    RAISE_ERRNO(RuntimeException, "read() failed");
  }

  buf_pos_ = 0;
  buf_len_ = bytes_read;
}

}
}