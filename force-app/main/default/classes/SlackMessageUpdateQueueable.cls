public without sharing class SlackMessageUpdateQueueable implements Queueable, Database.AllowsCallouts {
    
    private Id caseId;
    private String channelId;
    private String messageTs;
    private String statusBanner;

    public SlackMessageUpdateQueueable(Id caseId, String channelId, String messageTs, String statusBanner) {
        this.caseId = caseId;
        this.channelId = channelId;
        this.messageTs = messageTs;
        this.statusBanner = statusBanner;
    }

    public void execute(QueueableContext context) {
        Case c = [SELECT Id, CaseNumber, Subject, Priority, Status FROM Case WHERE Id = :caseId LIMIT 1];

        List<Object> updatedBlocks = new List<Object>{
            new Map<String, Object>{
                'type' => 'header',
                'text' => new Map<String, Object>{
                    'type' => 'plain_text',
                    'text' => '🚨 Critical Incident: ' + c.CaseNumber,
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
                'type' => 'context',
                'elements' => new List<Object>{
                    new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => statusBanner }
                }
            }
        };

        Map<String, Object> bodyMap = new Map<String, Object>{
            'channel' => this.channelId,
            'ts' => this.messageTs,
            'text' => 'Incident ' + c.CaseNumber + ' updated',
            'blocks' => updatedBlocks
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Slack_API/chat.update');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setBody(JSON.serialize(bodyMap));

        Http http = new Http();
        HttpResponse res = http.send(req);

        SlackCalloutService.createLog(c.Id, 'Outbound', 'callout:Slack_API/chat.update', res.getStatusCode(), 
                                      res.getStatusCode() == 200 ? 'Success' : 'Failed', 0, res.getBody());
    }
}