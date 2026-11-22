--!strict
-- Crash injection for one simulated server. Every handle the server holds (DataStore or sorted
-- map) shares one Faults, so one counter numbers all of that server's writes in order.
--
-- `arm(k, "stop")` raises CRASH before write k is applied and kills the server: every later call
-- through any of its handles, reads included, raises CRASH too. `arm(k, "lost")` lets write k land
-- and then raises, as a call whose response never arrived does, and the server carries on.
local Faults = {}
Faults.__index = Faults

export type Mode = "stop" | "lost"

export type Faults = typeof(setmetatable(
	{} :: {
		writes: number,
		dead: boolean,
		target: number?, -- the write number that is armed
		mode: Mode,
	},
	Faults
))

function Faults.new(): Faults
	return setmetatable({ writes = 0, dead = false, target = nil, mode = "stop" :: Mode }, Faults)
end

-- Arms write number k, counted from this call (the next write is 1).
function Faults.arm(self: Faults, k: number, mode: Mode)
	assert(k == math.floor(k) and k >= 1, "k must be a whole number from 1")
	assert(mode == "stop" or mode == "lost", "mode must be stop or lost")
	self.target = self.writes + k
	self.mode = mode
end

-- Called at the start of every read. A dead server raises; a read is not a write.
function Faults.beforeRead(self: Faults)
	if self.dead then
		error("CRASH")
	end
end

-- Called at the start of every write, before it is applied. Raises CRASH for a dead server or for
-- an armed "stop". Returns "lost" when the write must be applied and then followed by
-- `Faults.lose`.
function Faults.beforeWrite(self: Faults): Mode?
	if self.dead then
		error("CRASH")
	end
	self.writes += 1
	if self.target ~= nil and self.writes == self.target then
		self.target = nil
		if self.mode == "stop" then
			self.dead = true
			error("CRASH")
		end
		return "lost"
	end
	return nil
end

function Faults.lose()
	error("lost response")
end

return Faults
