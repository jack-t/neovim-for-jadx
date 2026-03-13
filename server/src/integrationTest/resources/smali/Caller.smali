.class public Lcom/example/Caller;
.super Ljava/lang/Object;

.method public call()V
    .registers 2
    new-instance v0, Lcom/example/Hello;
    invoke-direct {v0}, Lcom/example/Hello;-><init>()V
    invoke-virtual {v0}, Lcom/example/Hello;->greet()Ljava/lang/String;
    return-void
.end method
