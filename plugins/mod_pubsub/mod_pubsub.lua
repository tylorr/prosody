local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local usermanager = require "core.usermanager";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local autocreate_on_publish = module:get_option_boolean("autocreate_on_publish", false);
local autocreate_on_subscribe = module:get_option_boolean("autocreate_on_subscribe", false);
local pubsub_disco_name = module:get_option("name");
if type(pubsub_disco_name) ~= "string" then pubsub_disco_name = "Prosody PubSub Service"; end
local expose_publisher = module:get_option_boolean("expose_publisher", false)

local service;

local lib_pubsub = module:require "pubsub";
local handlers = lib_pubsub.handlers;
local pubsub_error_reply = lib_pubsub.pubsub_error_reply;

module:depends("disco");
module:add_identity("pubsub", "service", pubsub_disco_name);
module:add_feature("http://jabber.org/protocol/pubsub");

local feature_map = {
	get_subscriptions = { "retrieve-subscriptions" };
	get_affiliations = { "retrieve-affiliations" };
	set_subscribe = { "subscribe" };
	set_unsubscribe = { dependency = "set_subscribe" };
	get_options = { "subscription-options" };
	get_default = { "retrieve-default-sub"; dependency = "get_options" };
	set_options = { dependency = "get_options" };
	get_items = { "retrieve-items" };
	set_publish = { "publish", "item-ids", autocreate_on_publish and "auto-create" };
	set_retract = { "delete-items", "retract-items" };
	set_create = { "create-nodes", "instant-nodes" };
	set_create_configure = { "create-and-configure"; dependency = "set_create" };
	set_owner_delete = { "delete-nodes"; dependency = "set_create" };
	get_owner_configure = { "config-node" };
	get_owner_default = { "retrieve-default"; dependency = "get_owner_configure" };
	set_owner_configure = { dependency = "get_owner_configure" };
	set_owner_purge = { "purge-nodes" };
	get_owner_subscriptions = { "manage-subscriptions" };
	set_owner_subscriptions = { dependency = "get_owner_subscriptions" };
	get_owner_affiliations = { "modify-affiliations" };
	set_owner_affiliations = { dependency = "get_owner_affiliations" };
};

local get_not_implemented_reply;
local function get_handler(method, stanza)
	local handler = handlers[method];
	if handler then
		return true, handler;
	else
		return get_not_implemented_reply(method, stanza);
	end
end

get_not_implemented_reply = function(method, stanza)
	local features = feature_map[method];
	local reply;
	if features then
		local ok = true
		local ret;
		if features.dependency then
			ok, ret = get_handler(features.dependency, stanza);
		end
		if ok then
			local feature = features and features[1] or nil;
			reply = feature and pubsub_error_reply(stanza, "not-implemented", feature) or nil;
		else
			reply = ret;
		end
	end
	return false, reply;
end

function handle_pubsub_iq(event, namespace)
	local origin, stanza = event.origin, event.stanza;
	local pubsub = stanza.tags[1];
	local actions = pubsub.tags;
	if not #actions then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request"));
	end

	local action_names = {};
	for _, action in ipairs(actions) do
		table.insert(action_names, action.name) 
	end

	local ns_ = namespace and namespace.."_" or "";
	local compound_action = table.concat(action_names, "_");
	local method = stanza.attr.type.."_"..ns_..compound_action;

	local ok, ret = get_handler(method, stanza);

	if ok then
		actions = #actions == 1 and actions[1] or actions;

		local handler = ret;
		handler(origin, stanza, actions, service);
		return true;
	else
		local not_implemented_reply = ret;
		if not_implemented_reply then
			origin.send(not_implemented_reply);
			return true;
		end
	end

	return false;
end

function handle_pubsub_owner_iq(event)
	return handle_pubsub_iq(event, "owner");
end

function simple_broadcast(kind, node, jids, item, actor)
	if item then
		item = st.clone(item);
		item.attr.xmlns = nil; -- Clear the pubsub namespace
		if expose_publisher and actor then
			item.attr.publisher = actor
		end
	end
	local message = st.message({ from = module.host, type = "headline" })
		:tag("event", { xmlns = xmlns_pubsub_event })
			:tag(kind, { node = node })
				:add_child(item);
	for jid in pairs(jids) do
		module:log("debug", "Sending notification to %s", jid);
		message.attr.to = jid;
		module:send(message);
	end
end

module:hook("iq/host/"..xmlns_pubsub..":pubsub", handle_pubsub_iq);
module:hook("iq/host/"..xmlns_pubsub_owner..":pubsub", handle_pubsub_owner_iq);

local function add_disco_features_from_service(service)
	for affiliation in pairs(service.config.capabilities) do
		if affiliation ~= "none" and affiliation ~= "owner" then
			module:add_feature(xmlns_pubsub.."#"..affiliation.."-affiliation");
		end
	end
end

local function add_disco_features_from_handlers()
	for method, features in pairs(feature_map) do
		if handlers[method] then
			for _, feature in ipairs(features) do
				if feature then
					module:add_feature(xmlns_pubsub.."#"..feature);
				end
			end
		end
	end
end

module:hook("host-disco-info-node", function (event)
	local stanza, origin, reply, node = event.stanza, event.origin, event.reply, event.node;
	local ok, ret = service:get_nodes(stanza.attr.from);
	if not ok or not ret[node] then
		return;
	end
	event.exists = true;
	reply:tag("identity", { category = "pubsub", type = "leaf" });
end);

module:hook("host-disco-items-node", function (event)
	local stanza, origin, reply, node = event.stanza, event.origin, event.reply, event.node;
	local ok, ret = service:get_items(node, stanza.attr.from);
	if not ok then
		return;
	end

	for _, id in ipairs(ret) do
		reply:tag("item", { jid = module.host, name = id }):up();
	end
	event.exists = true;
end);


module:hook("host-disco-items", function (event)
	local stanza, origin, reply = event.stanza, event.origin, event.reply;
	local ok, ret = service:get_nodes(event.stanza.attr.from);
	if not ok then
		return;
	end
	for node, node_obj in pairs(ret) do
		reply:tag("item", { jid = module.host, node = node, name = node_obj.config.name }):up();
	end
end);

local admin_aff = module:get_option_string("default_admin_affiliation", "owner");
local unowned_aff = module:get_option_string("default_unowned_affiliation");
local function get_affiliation(jid, node)
	local bare_jid = jid_bare(jid);
	if bare_jid == module.host or usermanager.is_admin(bare_jid, module.host) then
		return admin_aff;
	end
	if not node then
		return unowned_aff;
	end
end

function set_service(new_service)
	service = new_service;
	module.environment.service = service;
	add_disco_features_from_service(service);
	add_disco_features_from_handlers();
end

function module.save()
	return { service = service };
end

function module.restore(data)
	set_service(data.service);
end

function module.load()
	if module.reloading then return; end

	set_service(pubsub.new({
		capabilities = {
			none = {
				create = false;
				publish = false;
				retract = false;
				get_nodes = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;

				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = false;
			};
			publisher = {
				create = false;
				publish = true;
				retract = true;
				get_nodes = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;

				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = false;
			};
			owner = {
				create = true;
				publish = true;
				retract = true;
				delete = true;
				get_nodes = true;
				configure = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;


				subscribe_other = true;
				unsubscribe_other = true;
				get_subscription_other = true;
				get_subscriptions_other = true;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = true;
			};
		};

		autocreate_on_publish = autocreate_on_publish;
		autocreate_on_subscribe = autocreate_on_subscribe;

		broadcaster = simple_broadcast;
		get_affiliation = get_affiliation;

		normalize_jid = jid_bare;
	}));
end
