trigger SlackActionEventTrigger on Slack_Action_Event__e (after insert) {
    List<Case> casesToUpdate = new List<Case>();

    for (Slack_Action_Event__e evt : Trigger.New) {
        if (String.isBlank(evt.Case_Id__c)) continue;

        Case c = new Case(Id = evt.Case_Id__c);
        String actionSummary = '';

        if (evt.Action_Id__c == 'claim_case') {
            c.Status = 'Working';
            c.Slack_Sync_Status__c = 'Acknowledged';
            actionSummary = '✅ *Claimed by <@' + evt.Slack_User_Id__c + '>* (' + evt.Slack_User_Name__c + ')';
        } else if (evt.Action_Id__c == 'escalate_case') {
            c.Status = 'Escalated';
            c.Slack_Sync_Status__c = 'Acknowledged';
            actionSummary = '🔥 *Escalated to Tier 2 by <@' + evt.Slack_User_Id__c + '>* (' + evt.Slack_User_Name__c + ')';
        }

        casesToUpdate.add(c);
        System.enqueueJob(new SlackMessageUpdateQueueable(c.Id, evt.Channel_Id__c, evt.Message_TS__c, actionSummary));
    }

    if (!casesToUpdate.isEmpty()) {
        update casesToUpdate;
    }
}