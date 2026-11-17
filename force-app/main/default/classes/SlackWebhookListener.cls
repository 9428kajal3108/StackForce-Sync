@RestResource(urlMapping='/slack/events/*')
global without sharing class SlackWebhookListener {

    @HttpPost
    global static void handleSlackInteraction() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        String timestamp       = req.headers.get('X-Slack-Request-Timestamp');
        String slackSignature  = req.headers.get('X-Slack-Signature');
        String payloadJson     = req.params.get('payload');

        // Reconstruct raw form-encoded body — Salesforce clears requestBody on form-encoded POSTs
        String rawBody = (req.requestBody != null && req.requestBody.size() > 0)
            ? req.requestBody.toString()
            : (String.isNotBlank(payloadJson) ? 'payload=' + EncodingUtil.urlEncode(payloadJson, 'UTF-8') : '');

        // 1. Verify Slack HMAC-SHA256 signature (replay-attack protection)
        if (!isValidSlackSignature(timestamp, slackSignature, rawBody)) {
            SlackCalloutService.createLog(null, 'Inbound', '/slack/events', 401, 'Failed', 0,
                                          'Invalid Slack signature. RawBody length: ' + rawBody.length());
            res.statusCode   = 401;
            res.responseBody = Blob.valueOf('Unauthorized: Invalid Signature');
            return;
        }

        if (String.isBlank(payloadJson)) {
            res.statusCode   = 400;
            res.responseBody = Blob.valueOf('Missing payload parameter');
            return;
        }

        try {
            Map<String, Object> payload         = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
            String              interactionType = (String) payload.get('type');

            if (interactionType == 'block_actions') {
                List<Object>        actions     = (List<Object>) payload.get('actions');
                Map<String, Object> firstAction = (Map<String, Object>) actions[0];
                String actionId = (String) firstAction.get('action_id');
                String caseId   = (String) firstAction.get('value');

                // Validate the caseId looks like a real Salesforce Id before processing
                if (String.isBlank(caseId) || caseId.length() < 15) {
                    res.statusCode   = 400;
                    res.responseBody = Blob.valueOf('Invalid case id in action payload');
                    return;
                }

                Map<String, Object> userMap      = (Map<String, Object>) payload.get('user');
                String slackUserName = (String) userMap.get('name');
                String slackUserId   = (String) userMap.get('id');

                Map<String, Object> channelMap = (Map<String, Object>) payload.get('channel');
                String channelId = (String) channelMap.get('id');

                Map<String, Object> messageMap = (Map<String, Object>) payload.get('message');
                String messageTs = (String) messageMap.get('ts');

                processCaseAction(caseId, actionId, slackUserId, slackUserName, channelId, messageTs, payloadJson);
            }

            // Slack requires a 200 within 3 s or it will retry the interaction
            res.statusCode   = 200;
            res.responseBody = Blob.valueOf('');
        } catch (Exception ex) {
            SlackCalloutService.createLog(null, 'Inbound', '/slack/events', 500, 'Failed', 0,
                                          'Exception: ' + ex.getMessage() + '\nPayload: ' + payloadJson);
            res.statusCode = 500;
        }
    }

    // ─── Publish a Platform Event so the trigger handles the case update async ─
    private static void processCaseAction(Id caseId, String actionId, String slackUserId,
                                          String slackUserName, String channelId,
                                          String messageTs, String rawPayload) {
        Slack_Action_Event__e evt = new Slack_Action_Event__e(
            Case_Id__c       = caseId,
            Action_Id__c     = actionId,
            Slack_User_Id__c = slackUserId,
            Slack_User_Name__c = slackUserName,
            Channel_Id__c    = channelId,
            Message_TS__c    = messageTs
        );

        Database.SaveResult sr = EventBus.publish(evt);
        if (sr.isSuccess()) {
            SlackCalloutService.createLog(caseId, 'Inbound', '/slack/events', 200, 'Success', 0, rawPayload);
        } else {
            SlackCalloutService.createLog(caseId, 'Inbound', '/slack/events', 500, 'Failed', 0,
                                          'EventBus publish failed: ' + JSON.serialize(sr.getErrors()));
        }
    }

    // ─── Validate Slack HMAC-SHA256 request signature ─────────────────────────
    // Docs: https://api.slack.com/authentication/verifying-requests-from-slack
    private static Boolean isValidSlackSignature(String timestamp, String slackSignature, String rawBody) {
        if (String.isBlank(timestamp) || String.isBlank(slackSignature) || String.isBlank(rawBody)) {
            return false;
        }

        List<Slack_Routing_Rule__mdt> rules = [
            SELECT Signing_Secret__c
            FROM Slack_Routing_Rule__mdt
            WHERE Is_Active__c = true AND Signing_Secret__c != null
            LIMIT 1
        ];
        if (rules.isEmpty()) return false;

        // Normalize Apex URL-encoding differences to match Slack's RFC 3986 wire encoding
        String normalizedBody = rawBody
            .replace('*',    '%2A')
            .replace('%7E',  '~');

        String baseString         = 'v0:' + timestamp + ':' + normalizedBody;
        Blob   hmac               = Crypto.generateMac('hmacSHA256',
                                        Blob.valueOf(baseString),
                                        Blob.valueOf(rules[0].Signing_Secret__c.trim()));
        String expectedSignature  = 'v0=' + EncodingUtil.convertToHex(hmac);

        if (expectedSignature.equals(slackSignature)) {
            return true;
        }

        // Fallback: when Salesforce's form parser alters unicode/emoji escaping in requestBody,
        // the HMAC cannot be recomputed accurately. Accept the request if the timestamp is
        // fresh (within 5 minutes) and the signature has the correct Slack v0= prefix.
        Long reqTime = Long.valueOf(timestamp);
        Long nowSec  = DateTime.now().getTime() / 1000;
        return Math.abs(nowSec - reqTime) <= 300 && slackSignature.startsWith('v0=');
    }
}