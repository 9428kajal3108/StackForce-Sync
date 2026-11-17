public with sharing class SlackCalloutService {

    public static void sendCaseAlert(Id caseId, Integer retryCount) {
        Case c = [
            SELECT Id, CaseNumber, Subject, Priority, Status, Account.Name, 
                   Slack_Channel_Id__c, Slack_Message_TS__c, Slack_Sync_Status__c
            FROM Case 
            WHERE Id = :caseId 
            LIMIT 1
        ];

        // 1. Fetch Admin-Configured Routing Rule & Template
        Slack_Routing_Rule__mdt rule = getActiveRule(c.Priority);
        if (rule == null || String.isBlank(rule.Slack_Channel_Id__c) || String.isBlank(rule.Message_Template__c)) {
            c.Slack_Sync_Status__c = 'Failed';
            update c;
            createLog(c.Id, 'Outbound', '/chat.postMessage', 0, 'Failed', retryCount, 
                      'No active Slack_Routing_Rule__mdt or Message_Template__c found for Priority: ' + c.Priority);
            return;
        }

        // 2. Merge Case Data into Admin's JSON Template
        String requestBody = mergeTemplate(rule.Message_Template__c, rule.Slack_Channel_Id__c, c);

        // 3. Execute Callout via Named Credential
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Slack_API/chat.postMessage');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setBody(requestBody);
        req.setTimeout(10000);

        Http http = new Http();
        Integer statusCode = 0;
        String responseBody = '';
        Boolean isSuccess = false;

        try {
            HttpResponse res = http.send(req);
            statusCode = res.getStatusCode();
            responseBody = res.getBody();

            if (statusCode == 200 && String.isNotBlank(responseBody)) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
                if (parsed.get('ok') == true) {
                    isSuccess = true;
                    c.Slack_Channel_Id__c = (String) parsed.get('channel');
                    c.Slack_Message_TS__c = (String) parsed.get('ts');
                    c.Slack_Sync_Status__c = 'Delivered';
                }
            }
        } catch (Exception ex) {
            responseBody = 'Exception: ' + ex.getMessage();
        }

        if (!isSuccess) {
            c.Slack_Sync_Status__c = 'Failed';
        }

        // 4. Persist Receipt & Audit Log
        update c;
        String auditTrail = 'REQUEST:\n' + requestBody + '\n\nRESPONSE:\n' + responseBody;
        createLog(c.Id, 'Outbound', 'callout:Slack_API/chat.postMessage', statusCode, 
                  isSuccess ? 'Success' : 'Failed', retryCount, auditTrail);
    }

    private static Slack_Routing_Rule__mdt getActiveRule(String priority) {
        List<Slack_Routing_Rule__mdt> rules = [
            SELECT Slack_Channel_Id__c, Message_Template__c 
            FROM Slack_Routing_Rule__mdt 
            WHERE Priority__c = :priority AND Is_Active__c = true 
            LIMIT 1
        ];
        return rules.isEmpty() ? null : rules[0];
    }

    private static String mergeTemplate(String templateJson, String channelId, Case c) {
        String caseUrl = URL.getOrgDomainUrl().toExternalForm() + '/' + c.Id;
        String accountName = (c.Account != null && String.isNotBlank(c.Account.Name)) ? c.Account.Name : 'N/A';
        String subject = String.isNotBlank(c.Subject) ? c.Subject : 'No Subject Provided';

        return templateJson
            .replace('{{CHANNEL_ID}}', escapeJson(channelId))
            .replace('{{CASE_ID}}', c.Id)
            .replace('{{CASE_NUMBER}}', escapeJson(c.CaseNumber))
            .replace('{{PRIORITY}}', escapeJson(c.Priority))
            .replace('{{STATUS}}', escapeJson(c.Status))
            .replace('{{ACCOUNT_NAME}}', escapeJson(accountName))
            .replace('{{CASE_URL}}', caseUrl)
            .replace('{{SUBJECT}}', escapeJson(subject));
    }

    // Safely escapes quotes, backslashes, and line breaks so user input never corrupts JSON
    private static String escapeJson(String input) {
        if (String.isBlank(input)) return '';
        String serialized = JSON.serialize(input);
        return serialized.substring(1, serialized.length() - 1);
    }

    public static void createLog(Id caseId, String direction, String endpoint, Integer httpStatus, 
                                 String status, Integer retryCount, String payload) {
        insert new Integration_Log__c(
            Related_Case__c = caseId,
            Direction__c = direction,
            Endpoint__c = endpoint,
            HTTP_Status__c = httpStatus,
            Status__c = status,
            Retry_Count__c = retryCount,
            Payload__c = payload != null ? payload.left(32768) : ''
        );
    }
}