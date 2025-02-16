--[[ Copyright (c) 2017 Optera
 * Part of Logistics Train Network
 *
 * See LICENSE.md in the project directory for license information.
--]]

Get_Distance = require('__flib__.position').distance
Get_Main_Locomotive = require('__flib__.train').get_main_locomotive
Get_Train_Name = require('__flib__.train').get_backer_name

require 'script.constants'
require 'script.settings'
require 'script.print'
require 'script.alert'
require 'script.utils'         -- requires settings
require 'script.hotkey-events' -- requires print

require 'script.stop-update'
require 'script.dispatcher'
require 'script.stop-events'
require 'script.train-events'
require 'script.train-interface'   -- requires train-events
require 'script.surface-interface' -- requires stop-events
require 'script.interface'         -- ties into other modules
require 'script.init'              -- requires other modules loaded first
