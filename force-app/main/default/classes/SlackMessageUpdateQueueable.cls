public with sharing class SlackMessageUpdateQueueable implements Queueable, Database.AllowsCallouts {

    private Id     caseId;
    private String channelId;
    private String messageTs;
    private String statusBanner;

    public SlackMessageUpdateQueueable(Id caseId, String channelId, String messageTs, String statusBanner) {
        this.caseId       = caseId;
        this.channelId    = channelId;
        this.messageTs    = messageTs;
        this.statusBanner = statusBanner;
    }

    public void execute(QueueableContext context) {
        // Guard: skip callout when channelId or messageTs is missing
        if (String.isBlank(this.channelId) || String.isBlank(this.messageTs)) {
            SlackCalloutService.createLog(this.caseId, 'Outbound', 'callout:Slack_API/chat.update',
                                          0, 'Failed', 0,
                                          'Skipped: channelId or messageTs is blank for Case ' + this.caseId);
            return;
        }

        Case c = [SELECT Id, CaseNumber, Subject, Priority, Status FROM Case WHERE Id = :caseId LIMIT 1];

        // Rebuild the message body with updated status and disabled action buttons
        List<Object> updatedBlocks = buildUpdatedBlocks(c);

        Map<String, Object> bodyMap = new Map<String, Object>{
            'channel' => this.channelId,
            'ts'      => this.messageTs,
            'text'    => 'Incident ' + c.CaseNumber + ' updated',
            'blocks'  => updatedBlocks
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Slack_API/chat.update');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setBody(JSON.serialize(bodyMap));
        req.setTimeout(10000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        Boolean isSuccess = (res.getStatusCode() == 200);
        SlackCalloutService.createLog(c.Id, 'Outbound', 'callout:Slack_API/chat.update',
                                      res.getStatusCode(),
                                      isSuccess ? 'Success' : 'Failed',
                                      0, res.getBody());
    }

    // ─── Build the updated Slack Block Kit layout ──────────────────────────────
    private List<Object> buildUpdatedBlocks(Case c) {
        return new List<Object>{
            new Map<String, Object>{
                'type' => 'header',
                'text' => new Map<String, Object>{
                    'type'  => 'plain_text',
                    'text'  => 'Critical Incident: ' + c.CaseNumber,
                    'emoji' => true
                }
            },
            new Map<String, Object>{
                'type' => 'section',
                'text' => new Map<String, Object>{
                    'type' => 'mrkdwn',
                    'text' => '*Issue Summary:*\n' + c.Subject + '\n\n*Current Status:* ' + c.Status
                }
            },
            new Map<String, Object>{ 'type' => 'divider' },
            new Map<String, Object>{
                'type'     => 'context',
                'elements' => new List<Object>{
                    new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => this.statusBanner }
                }
            }
        };
    }
}