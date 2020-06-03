//This file deals with distress beacons. It randomizes between a number of different types when activated.
//There's also an admin commmand which lets you set one to your liking.




//basic persistent gamemode stuff.
/datum/game_mode
	var/list/datum/emergency_call/all_calls = list() //initialized at round start and stores the datums.
	var/datum/emergency_call/picked_call = null //Which distress call is currently active
	var/has_called_emergency = FALSE
	var/distress_cooldown = 0
	var/waiting_for_candidates = FALSE

//The distress call parent. Cannot be called itself due to "name" being a filtered target.
/datum/emergency_call
	var/name = "name"
	var/mob_max = 3
	var/mob_min = 3
	var/dispatch_message = "An encrypted signal has been received from a nearby vessel. Stand by." //Msg to display when starting
	var/arrival_message = "" //Msg to display about when the shuttle arrives
	var/objectives //Txt of objectives to display to joined. Todo: make this into objective notes
	var/objective_info //For additional info in the objectives txt
	var/probability = 0 //Chance of it occuring. Total must equal 100%
	var/hostility //For ERTs who are either hostile or friendly by random chance.
	var/list/datum/mind/members = list() //Currently-joined members.
	var/list/datum/mind/candidates = list() //Potential candidates for enlisting.
	var/name_of_spawn = "Distress" //If we want to set up different spawn locations
	var/mob/living/carbon/leader = null //Who's leading these miscreants
	var/medics = 0
	var/heavies = 0
	var/max_medics = 1
	var/max_heavies = 1
	var/shuttle_id = "Distress" //Empty shuttle ID means we're not using shuttles (aka spawn straight into cryo)
	var/auto_shuttle_launch = FALSE

/datum/game_mode/proc/initialize_emergency_calls()
	if(all_calls.len) //It's already been set up.
		return

	var/list/total_calls = typesof(/datum/emergency_call)
	if(!total_calls.len)
		to_world(SPAN_DANGER("\b Error setting up emergency calls, no datums found."))
		return FALSE
	for(var/S in total_calls)
		var/datum/emergency_call/C= new S()
		if(!C)	continue
		if(C.name == "name") continue //The default parent, don't add it
		all_calls += C

//Randomizes and chooses a call datum.
/datum/game_mode/proc/get_random_call()
	var/add_prob = 0
	var/datum/emergency_call/chosen_call
	var/total_probablity = 0

	//Ensure that if someone messed up the math we still get the good probability
	for(var/datum/emergency_call/E in all_calls)
		total_probablity += E.probability
	var/chance = rand(1, total_probablity)

	for(var/datum/emergency_call/E in all_calls) //Loop through all potential candidates
		if(chance >= E.probability + add_prob) //Tally up probabilities till we find which one we landed on
			add_prob += E.probability
			continue
		chosen_call = E //Our random chance found one.
		break

	if(!istype(chosen_call))
		error("get_random_call !istype(chosen_call)")
		return null
	else
		return chosen_call

/datum/game_mode/proc/get_specific_call(var/call_name, var/announce = TRUE, var/is_emergency = TRUE, var/info = "")
	for(var/datum/emergency_call/E in all_calls) //Loop through all potential candidates
		if(E.name == call_name)
			picked_call = E
			picked_call.objective_info = info
			picked_call.activate(announce, is_emergency)
			return
	error("get_specific_call could not find emergency call '[call_name]'")
	return

/datum/emergency_call/proc/show_join_message()
	if(!mob_max || !ticker || !ticker.mode) //Just a supply drop, don't bother.
		return

	for(var/mob/dead/observer/M in player_list)
		if(M.client)
			to_chat(M, FONT_SIZE_LARGE("\n<span class='attack'>An emergency beacon has been activated. Use the <B>Ghost > Join Response Team</b> verb to join!</span>"))
			to_chat(M, "<span class='attack'>You cannot join if you have Ghosted recently.</span>\n")

/datum/game_mode/proc/activate_distress()
	picked_call = get_random_call()
	if(!istype(picked_call, /datum/emergency_call)) //Something went horribly wrong
		return
	if(ticker && ticker.mode && ticker.mode.waiting_for_candidates) //It's already been activated
		return
	picked_call.activate()
	return

/mob/dead/observer/verb/JoinResponseTeam()
	set name = "Join Response Team"
	set category = "Ghost"
	set desc = "Join an ongoing distress call response. You must be ghosted to do this."

	if(jobban_isbanned(usr, "Syndicate") || jobban_isbanned(usr, "Emergency Response Team"))
		to_chat(usr, SPAN_DANGER("You are jobbanned from the emergency response team!"))
		return
	if(!ticker || !ticker.mode || isnull(ticker.mode.picked_call))
		to_chat(usr, SPAN_WARNING("No distress beacons are active. You will be notified if this changes."))
		return

	var/datum/emergency_call/distress = ticker.mode.picked_call //Just to simplify things a bit
	if(!istype(distress) || !distress.mob_max)
		to_chat(usr, SPAN_WARNING("The emergency response team is already full!"))
		return
	var/deathtime = world.time - usr.timeofdeath

	if(deathtime < 600) //Nice try, ghosting right after the announcement
		if(map_tag != MAP_WHISKEY_OUTPOST) // people ghost so often on whiskey outpost.
			to_chat(usr, SPAN_WARNING("You ghosted too recently."))
			return

	if(!ticker.mode.waiting_for_candidates)
		to_chat(usr, SPAN_WARNING("The emergency response team has already been selected."))
		return

	if(!usr.mind) //How? Give them a new one anyway.
		usr.mind = new /datum/mind(usr.key, usr.ckey)
		usr.mind.active = 1
		usr.mind.current = usr
		usr.mind_initialize()
	if(usr.mind.key != usr.key)
		usr.mind.key = usr.key //Sigh. This can happen when admin-switching people into afking people, leading to runtime errors for a clientless key.

	if(!usr.client || !usr.mind)
		return //Somehow
	if(usr.mind in distress.candidates)
		to_chat(usr, SPAN_WARNING("You are already a candidate for this emergency response team."))
		return

	if(distress.add_candidate(usr))
		to_chat(usr, SPAN_BOLDNOTICE("You are now a candidate in the emergency response team! If there are enough candidates, you may be picked to be part of the team."))
	else
		to_chat(usr, SPAN_WARNING("You did not get enlisted in the response team. Better luck next time!"))

/datum/emergency_call/proc/activate(announce = TRUE, is_emergency = FALSE)
	set waitfor = 0
	if(!ticker || !ticker.mode) //Something horribly wrong with the gamemode ticker
		return

	if(is_emergency && ticker.mode.has_called_emergency) //It's already been called.
		return

	if(mob_max > 0)
		ticker.mode.waiting_for_candidates = TRUE
	show_join_message() //Show our potential candidates the message to let them join.
	message_admins("Distress beacon: '[name]' activated [src.hostility? "[SPAN_WARNING("(THEY ARE HOSTILE)")]":"(they are friendly)"]. Looking for candidates.")

	if(announce)
		marine_announcement("A distress beacon has been launched from the [MAIN_SHIP_NAME].", "Priority Alert", 'sound/AI/distressbeacon.ogg')

	if(is_emergency) //non-emergency ERTs don't count as emergency
		ticker.mode.has_called_emergency = TRUE

	add_timer(CALLBACK(src, /datum/emergency_call/proc/spawn_candidates, announce), SECONDS_60)

/datum/emergency_call/proc/spawn_candidates(announce = TRUE)
	if(candidates.len < mob_min)
		message_admins("Aborting distress beacon, not enough candidates: found [candidates.len].")
		ticker.mode.waiting_for_candidates = FALSE
		ticker.mode.has_called_emergency = FALSE
		members = list() //Empty the members list.
		candidates = list()

		if(announce)
			marine_announcement("The distress signal has not received a response, the launch tubes are now recalibrating.", "Distress Beacon")

		disable_calls()
		ticker.mode.picked_call = null
		add_timer(CALLBACK(src, /datum/emergency_call/proc/enable_calls), MINUTES_2)
	else //We've got enough!
		//Trim down the list
		var/list/datum/mind/picked_candidates = list()
		if(mob_max > 0)
			for(var/i in 1 to mob_max)
				if(!candidates.len) 
					break//We ran out of candidates, maybe they alienized. Use what we have.
				var/datum/mind/M = pick(candidates) //Get a random candidate, then remove it from the candidates list.
				if(isXeno(M.current) && M.current.stat != DEAD)
					candidates.Remove(M) //Strip them from the list, they aren't dead anymore.
					if(!candidates.len) 
						break //NO picking from empty lists
					M = pick(candidates)
				if(!istype(M))//Something went horrifically wrong
					candidates.Remove(M)
					continue //Lets try this again
				picked_candidates.Add(M)
				candidates.Remove(M)
			if(candidates.len)
				for(var/datum/mind/I in candidates)
					if(I.current)
						to_chat(I.current, SPAN_WARNING("You didn't get selected to join the distress team. Better luck next time!"))

		if(announce)
			marine_announcement(dispatch_message, "Distress Beacon", 'sound/AI/distressreceived.ogg') //Announcement that the Distress Beacon has been answered, does not hint towards the chosen ERT

		message_admins("Distress beacon: [src.name] finalized, setting up candidates.")

		//Let the deadchat know what's up since they are usually curious
		for(var/mob/dead/observer/M in player_list)
			if(M.client)
				to_chat(M, SPAN_NOTICE("Distress beacon: [src.name] finalized."))

		var/datum/shuttle/ferry/shuttle = shuttle_controller.shuttles[shuttle_id]
		if(!shuttle || !istype(shuttle))
			if(shuttle_id) //Cryo distress doesn't have a shuttle
				message_admins("Warning: Distress shuttle not found. Aborting.")
				return
		spawn_items()

		if(shuttle && auto_shuttle_launch)
			shuttle.launch()

		if(picked_candidates.len)
			var/i = 0
			for(var/datum/mind/M in picked_candidates)
				members += M
				i++
				if(i > mob_max)
					break //Some logic. Hopefully this will never happen..
				create_member(M)
		candidates = null //Blank out the candidates list for next time.
		candidates = list()
		ticker.mode.waiting_for_candidates = FALSE

/datum/emergency_call/proc/add_candidate(var/mob/M)
	if(!M.client || (M.mind && M.mind in candidates) || istype(M,/mob/living/carbon/Xenomorph))
		return FALSE //Not connected or already there or something went wrong.
	if(M.mind)
		candidates += M.mind
	else
		if(M.key)
			M.mind = new /datum/mind(M.key, M.ckey)
			M.mind_initialize()
			candidates += M.mind
	return TRUE

/datum/emergency_call/proc/get_spawn_point(is_for_items)
	var/list/spawn_list = list()

	for(var/obj/effect/landmark/L in landmarks_list)
		if(is_for_items && L.name == "[name_of_spawn]Item")
			spawn_list += L
		else
			if(L.name == name_of_spawn) //Default is "Distress"
				spawn_list += L

	if(!spawn_list.len) //Empty list somehow
		return null

	var/turf/spawn_loc	= get_turf(pick(spawn_list))
	if(!istype(spawn_loc))
		return null

	return spawn_loc

/datum/emergency_call/proc/disable_calls()
	ticker.mode.distress_cooldown = TRUE

/datum/emergency_call/proc/enable_calls()
	ticker.mode.distress_cooldown = FALSE

/datum/emergency_call/proc/create_member(datum/mind/M) //This is the parent, each type spawns its own variety.
	return

//Spawn various items around the shuttle area thing.
/datum/emergency_call/proc/spawn_items()
	return


/datum/emergency_call/proc/print_backstory(mob/living/carbon/human/M)
	return
