trigger SlackActionEventTrigger on Slack_Action_Event__e (after insert) {
    List<Case> casesToUpdate = new List<Case>();

    for (Slack_Action_Event__e evt : Trigger.New) {
        if (String.isBlank(evt.Case_Id__c) || String.isBlank(evt.Action_Id__c)) {
            continue;
        }

        Case   c             = new Case(Id = evt.Case_Id__c);
        String statusBanner  = '';

        if (evt.Action_Id__c == 'claim_case') {
            c.Status                   = 'Working';
            c.Claimed_By_Slack_User__c = evt.Slack_User_Name__c;
            c.Slack_Sync_Status__c     = 'Acknowledged';
            statusBanner = 'Claimed by <@' + evt.Slack_User_Id__c + '> (' + evt.Slack_User_Name__c + ')';

        } else if (evt.Action_Id__c == 'escalate_case') {
            c.Status              = 'Escalated';
            c.Slack_Sync_Status__c = 'Acknowledged';
            statusBanner = 'Escalated to Tier 2 by <@' + evt.Slack_User_Id__c + '> (' + evt.Slack_User_Name__c + ')';

        } else {
            // Unknown action — log and skip
            SlackCalloutService.createLog(evt.Case_Id__c, 'Inbound', '/slack/events', 0, 'Failed', 0,
                                          'Unknown action_id received: ' + evt.Action_Id__c);
            continue;
        }

        casesToUpdate.add(c);

        // Enqueue Slack message update only when we have the required Slack identifiers
        if (String.isNotBlank(evt.Channel_Id__c) && String.isNotBlank(evt.Message_TS__c)) {
            System.enqueueJob(new SlackMessageUpdateQueueable(c.Id, evt.Channel_Id__c, evt.Message_TS__c, statusBanner));
        }
    }

    if (!casesToUpdate.isEmpty()) {
        update casesToUpdate;
    }
}