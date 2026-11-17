public with sharing class SlackAlertQueueable implements Queueable, Database.AllowsCallouts {
    
    private Id caseId;
    private Integer retryCount;

    public SlackAlertQueueable(Id caseId, Integer retryCount) {
        this.caseId = caseId;
        this.retryCount = retryCount;
    }

    public void execute(QueueableContext context) {
        SlackCalloutService.sendCaseAlert(this.caseId, this.retryCount);
    }

    @InvocableMethod(label='Send Slack Critical Alert' description='Enqueues an outbound Slack alert using Custom Metadata templates')
    public static void enqueueFromFlow(List<Id> caseIds) {
        for (Id cId : caseIds) {
            System.enqueueJob(new SlackAlertQueueable(cId, 0));
        }
    }
}