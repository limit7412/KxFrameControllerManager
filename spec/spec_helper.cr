require "spec"
require "log"
require "file_utils"

require "../src/config/models"
require "../src/config/repository"
require "../src/config/usecase"
require "../src/error/usecase"
require "../src/steamvr/usecase"
require "./support/fakes"

Log.setup(:none)
