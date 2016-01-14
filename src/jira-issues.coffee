# Description:
#   Looks up jira issues when they're mentioned in chat
#
#   Will ignore users set in HUBOT_JIRA_IGNORE_USERS (by default, JIRA and GitHub).
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_JIRA_URL (format: "https://jira-domain.com:9090")
#   HUBOT_JIRA_IGNORECASE (optional; default is "true")
#   HUBOT_JIRA_USERNAME (optional)
#   HUBOT_JIRA_PASSWORD (optional)
#   HUBOT_JIRA_IGNORE_USERS (optional, format: "user1|user2", default is "jira|github")
#
# Commands:
#   hubot move jira <issue ID> to <status> - Changes the status of <issue ID> to <status>
#   hubot jira status - List the available statuses
#
# Author:
#   rustedgrail
#   stuartf

module.exports = (robot) ->
  cache = []

  # In case someone upgrades form the previous version, we'll default to the
  # previous behavior.
  jiraUrl = process.env.HUBOT_JIRA_URL || "https://#{process.env.HUBOT_JIRA_DOMAIN}"
  jiraUsername = process.env.HUBOT_JIRA_USERNAME
  jiraPassword = process.env.HUBOT_JIRA_PASSWORD

  if jiraUsername != undefined && jiraUsername.length > 0
    auth = "#{jiraUsername}:#{jiraPassword}"

  jiraIgnoreUsers = process.env.HUBOT_JIRA_ISSUES_IGNORE_USERS
  if jiraIgnoreUsers == undefined
    jiraIgnoreUsers = "jira|github"

  robot.http(jiraUrl + "/rest/api/2/project")
    .auth(auth)
    .get() (err, res, body) ->
      json = JSON.parse(body)
      jiraPrefixes = ( entry.key for entry in json )
      reducedPrefixes = jiraPrefixes.reduce (x,y) -> x + "-|" + y
      jiraPattern = "/\\b(" + reducedPrefixes + "-)(\\d+)\\b/g"
      ic = process.env.HUBOT_JIRA_IGNORECASE
      if ic == undefined || ic == "true"
        jiraPattern += "i"
      jiraPattern = eval(jiraPattern)

      robot.hear /move jira (.+) to (.+)/, (msg) ->
        issue = msg.match[1]
        msg.send "Getting transitions for #{issue}"
        robot.http(jiraUrl + "/rest/api/2/issue/#{issue}/transitions")
          .auth(auth).get() (err, res, body) ->
            jsonBody = JSON.parse(body)
            status = jsonBody.transitions.filter (trans) ->
              trans.name.toLowerCase() == msg.match[2].toLowerCase()
            if status.length == 0
              trans = jsonBody.transitions.map (trans) -> trans.name
              msg.send "The only transitions of #{issue} are: #{trans.reduce (t, s) -> t + "," + s}"
              return
            msg.send "Changing the status of #{issue} to #{status[0].name}"
            robot.http(jiraUrl + "/rest/api/2/issue/#{issue}/transitions")
              .header("Content-Type", "application/json").auth(auth).post(JSON.stringify({
                transition: status[0]
              })) (err, res, body) ->
                msg.send if res.statusCode == 204 then "Success!" else body

      robot.hear /jira status/, (msg) ->
        robot.http(jiraUrl + "/rest/api/2/status")
        .auth(auth).get() (err, res, body) ->
          response = "/code "
          for status in JSON.parse(body)
            response += status.name + ": " + status.description + '\n'
          msg.send response

      robot.hear jiraPattern, (msg) ->
        return if msg.message.user.name.match(new RegExp(jiraIgnoreUsers, "gi"))
        return if msg.message.text.match(new RegExp(/move jira (.+) to (.+)/))

        for i in msg.match
          issue = i.toUpperCase()
          now = new Date().getTime()
          if cache.length > 0
            cache.shift() until cache.length is 0 or cache[0].expires >= now

          msg.send item.message for item in cache when item.issue is issue

          if cache.length == 0 or (item for item in cache when item.issue is issue).length == 0
            robot.http(jiraUrl + "/rest/api/2/issue/" + issue)
              .auth(auth)
              .get() (err, res, body) ->
                try
                  json = JSON.parse(body)
                  key = json.key

                  message = "[" + key + "] " + json.fields.summary
                  message += '\nStatus: '+json.fields.status.name

                  if (json.fields.assignee == null)
                    message += ', unassigned'
                  else if ('value' of json.fields.assignee or 'displayName' of json.fields.assignee)
                    if (json.fields.assignee.name == "assignee" and json.fields.assignee.value.displayName)
                      message += ', assigned to ' + json.fields.assignee.value.displayName
                    else if (json.fields.assignee and json.fields.assignee.displayName)
                      message += ', assigned to ' + json.fields.assignee.displayName
                  else
                    message += ', unassigned'
                  message += ", rep. by "+json.fields.reporter.displayName
                  if json.fields.fixVersions and json.fields.fixVersions.length > 0
                    message += ', fixVersion: '+json.fields.fixVersions[0].name
                  else
                    message += ', fixVersion: NONE'

                  if json.fields.priority and json.fields.priority.name
                    message += ', priority: ' + json.fields.priority.name

                  urlRegex = new RegExp(jiraUrl + "[^\\s]*" + key)
                  if not msg.message.text.match(urlRegex)
                    message += "\n" + jiraUrl + "/browse/" + key

                  msg.send message
                  cache.push({issue: issue, expires: now + 120000, message: message})
                catch error
                  try
                    msg.send "[*ERROR*] " + json.errorMessages[0]
                  catch reallyError
                    msg.send "[*ERROR*] " + reallyError
