-- WoWClearance_Locale - player-facing string lookup.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- This version is English only. Player-facing strings are still wrapped at
-- the call site as L["English text"], and L returns the key unchanged. The
-- wrapper stays so a translation layer can come back without touching every
-- call site; the French / German templates and /wc locale were removed.
--
-- This file loads SECOND per the .toc (right after Core), so NS.L exists
-- before any other file binds `local L = NS.L` in its main chunk.

local NS = select(2, ...)

NS.L = setmetatable({}, {
    __index = function(_, k)
        return k
    end,
})
